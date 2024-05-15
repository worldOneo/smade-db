const std = @import("std");
const string = @import("./string.zig");
const alloc = @import("./alloc.zig");
const lock = @import("./lock.zig");
const state = @import("./state.zig");

const ValueTag = enum(usize) {
    LargeString = 0b00,
    SmallString = 0b01,
    List = 0b10,
    Complex = 0b11,
};

const ComplexValueTag = enum(usize) {
    Nil = 0b1,
    LongInt = 0b0,
};

const List = struct {
    length: usize,
    tail: ?*Node,
    head: ?*align(1) Node,

    const Node = struct {
        value: string.String,
        next: ?*Node,
        prev: ?*Node,
    };

    const This = @This();
    pub fn empty() This {
        var list = std.mem.zeroes(This);
        list.setHeadPtr(null);
        return list;
    }

    fn newNode(str: string.String, allocator: *alloc.LocalAllocator) ?*Node {
        const node = allocator.allocate(Node) orelse return null;
        node.next = null;
        node.prev = null;
        node.value = str;
        return node;
    }

    fn headPtr(this: *This) ?*Node {
        return @ptrFromInt(@intFromPtr(this.head) & ~@as(usize, 0b11));
    }

    fn setHeadPtr(this: *This, node: ?*Node) void {
        this.head = @ptrFromInt(@intFromPtr(node) | 0b10);
    }

    pub fn lpush(this: *This, node: *Node) void {
        this.length += 1;
        if (this.headPtr()) |head| {
            head.prev = node;
            node.next = head;
        } else {
            this.tail = node;
        }
        this.setHeadPtr(node);
    }

    pub fn lpop(this: *This) ?*Node {
        if (this.headPtr()) |head| {
            this.setHeadPtr(head.next);
            if (this.headPtr()) |new_head| {
                new_head.prev = null;
            } else {
                this.tail = null;
            }
            this.length -= 1;
            return head;
        }
        return null;
    }

    pub fn deinit(this: *This, la: *alloc.LocalAllocator) void {
        while (this.lpop()) |v| {
            la.free(Node, v);
        }
    }

    pub fn len(this: *This) usize {
        return this.length;
    }
};

pub const Value = struct {
    value: [3]usize,

    const This = @This();

    fn withLastByte(last: u8) This {
        var inner = [3]usize{ 0, 0, 0 };
        var sms = @as(*[24]u8, @ptrCast(&inner));
        sms[23] = last;
        const value = This{ .value = inner };
        return value;
    }

    pub fn nil() This {
        return withLastByte(0b111);
    }

    pub fn tag(this: *const This) ValueTag {
        var sms: *const [24]u8 = @ptrCast(this);
        return @enumFromInt(sms[23] & 0b11);
    }

    fn complexTag(this: *const This) ?ComplexValueTag {
        if (this.tag() == ValueTag.Complex) {
            var sms: *const [24]u8 = @ptrCast(this);
            return @enumFromInt((sms[23] >> 2) & 0b11);
        }
        return null;
    }

    pub fn isPresent(this: *const This) bool {
        if (this.complexTag()) |complex_tag| {
            return complex_tag != ComplexValueTag.Nil;
        }
        return true;
    }

    pub fn fromString(const_str: string.String) Value {
        var str = const_str;
        return .{ .value = @as(*[3]usize, @ptrCast(&str)).* };
    }

    pub fn fromInt(int: u64) Value {
        var this = withLastByte(0b11);
        this.value[0] = int;
        return this;
    }

    fn constCast(comptime Result: type, comptime Fn: *const fn (*This) ?*Result) *const fn (*const This) ?*const Result {
        return struct {
            fn cast(this: *const This) ?*const Result {
                var var_this = @constCast(this);
                if (Fn(var_this)) |v| {
                    return v;
                }
                return null;
            }
        }.cast;
    }

    pub fn asConstString(this: *const This) ?*const string.String {
        return constCast(string.String, asString)(this);
    }

    pub fn asString(this: *This) ?*string.String {
        const valueTag = this.tag();
        if (valueTag == .LargeString or valueTag == .SmallString) {
            return @ptrCast(this);
        }
        return null;
    }

    pub fn asLongInt(this: *This) ?u64 {
        if (this.complexTag() == .LongInt) {
            return this.value[0];
        }
        return null;
    }

    pub fn asConstList(this: *const This) ?*const List {
        return constCast(List, asList)(this);
    }

    pub fn asList(this: *This) ?*List {
        const valueTag = this.tag();
        if (valueTag != .List) {
            return null;
        }
        return @ptrCast(this);
    }

    pub fn deinit(this: *This, la: *alloc.LocalAllocator) void {
        if (this.asList()) |list| {
            list.deinit(la);
        } else if (this.asString()) |str| {
            str.deinit(la);
        }
        this.* = nil();
    }
};

pub const Entry = struct {
    key: string.String,
    value: Value,
    pub fn init(k: string.String, v: Value) @This() {
        return .{ .key = k, .value = v };
    }
};

fn Bucket() type {
    const bucketSize = 16;
    return struct {
        expire_items: usize = 0,
        metadatas: [bucketSize]u16,
        expiry: [bucketSize]u32,
        entries: [bucketSize]Entry,

        const This = @This();

        // leading zeroes = index
        const shifts_clz_vec = @Vector(bucketSize, u16){ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 };
        const clz_vec = @as(@Vector(bucketSize, u16), @splat(1)) << shifts_clz_vec;

        const shifts_clz_lower_vec = @Vector(8, u16){ 15, 14, 13, 12, 11, 10, 9, 8 };
        const clz_lower_vec = @as(@Vector(8, u16), @splat(1)) << shifts_clz_lower_vec;

        const shifts_clz_upper_vec = @Vector(8, u16){ 7, 6, 5, 4, 3, 2, 1, 0 };
        const clz_upper_vec = @as(@Vector(8, u16), @splat(1)) << shifts_clz_upper_vec;

        const hash_mask: u16 = (1 << 15) - 1;
        const present_mask: u16 = 1 << 15;
        const hash_mask_vec: @Vector(bucketSize, u16) = @splat(hash_mask);
        const zeroes: @Vector(bucketSize, u16) = @splat(0);

        fn clear(this: *This) void {
            for (0..bucketSize) |i| {
                this.metadatas[i] = 0;
            }
        }

        inline fn hasSpace(this: *const This) bool {
            const meta_vec = @Vector(bucketSize, u16){
                this.metadatas[0],
                this.metadatas[1],
                this.metadatas[2],
                this.metadatas[3],
                this.metadatas[4],
                this.metadatas[5],
                this.metadatas[6],
                this.metadatas[7],
                this.metadatas[8],
                this.metadatas[9],
                this.metadatas[10],
                this.metadatas[11],
                this.metadatas[12],
                this.metadatas[13],
                this.metadatas[14],
                this.metadatas[15],
            };
            const present: @Vector(bucketSize, u16) = @splat(present_mask);
            const meta_presents = meta_vec & present;
            return @reduce(.Any, meta_presents == present);
        }

        inline fn metaClzIdxFast(this: *const This, mask: u16, eq: u16) u16 {
            // a bit of SIMD to find the first indexes with a matching properties
            const mask_vec: @Vector(bucketSize, u16) = @splat(mask);
            const eq_vec: @Vector(bucketSize, u16) = @splat(eq);

            const meta_vec = @Vector(bucketSize, u16){
                this.metadatas[0],
                this.metadatas[1],
                this.metadatas[2],
                this.metadatas[3],
                this.metadatas[4],
                this.metadatas[5],
                this.metadatas[6],
                this.metadatas[7],
                this.metadatas[8],
                this.metadatas[9],
                this.metadatas[10],
                this.metadatas[11],
                this.metadatas[12],
                this.metadatas[13],
                this.metadatas[14],
                this.metadatas[15],
            };
            const masked_meta_vec = meta_vec & mask_vec;
            const eq_pred = masked_meta_vec == eq_vec;
            const clz_idxs = @select(u16, eq_pred, clz_vec, zeroes);
            const idxes = @reduce(.Or, clz_idxs);
            return idxes;
        }

        fn findIdxOf(this: *const This, shifted_hash: u64, key: *const string.String) ?usize {
            const one: u16 = 1;

            var clz_access = this.metaClzIdxFast(hash_mask | present_mask, @as(u16, @intCast(shifted_hash & @as(u64, @intCast(hash_mask)))) | present_mask);
            while (clz_access != 0) {
                const idx: u16 = @clz(clz_access); // get set bit
                clz_access ^= (one << 15) >> @intCast(idx); // unset bit
                if (this.entries[idx].key.eql(key)) {
                    return @intCast(idx);
                }
            }
            return null;
        }

        fn presentSlots(this: *const This) u16 {
            return this.metaClzIdxFast(present_mask, present_mask);
        }

        fn findEmptySlot(this: *const This) ?usize {
            var clz_access = this.metaClzIdxFast(present_mask, 0);
            if (clz_access == 0) {
                return null;
            }

            const idx: u16 = @clz(clz_access); // get set bit
            return @intCast(idx);
        }

        fn get(this: *const This, hash: u64, key: *const string.String, now: u32) ?*const Value {
            const maybe_idx = this.findIdxOf(hash, key);
            if (maybe_idx) |idx| {
                if (this.expiry[idx] == 0 or this.expiry[idx] > now) {
                    return &this.entries[idx].value;
                }
            }
            return null;
        }

        inline fn expiryClzIdx(expiries: @Vector(8, u32), now: u32, comptime clz: @Vector(8, u16)) u16 {
            const zeroes8_vec: @Vector(8, u32) = @splat(0);
            const now_vec: @Vector(8, u32) = @splat(now);
            const lt_vec = @select(u16, expiries < now_vec, clz, zeroes8_vec);
            const u32_zero_vec: @Vector(8, u32) = @splat(0);
            const neqz_vec = @select(u16, expiries != u32_zero_vec, clz, zeroes8_vec);
            return @reduce(.Or, lt_vec & neqz_vec);
        }

        fn removeExpired(this: *This, cclz_idx: u16, allocator: *alloc.LocalAllocator) u32 {
            var clz_idx = cclz_idx;
            const one: u16 = 1;
            var freed = @popCount(cclz_idx);

            while (clz_idx != 0) {
                const idx = @clz(clz_idx);
                clz_idx ^= (one << 15) >> @intCast(idx); // unset bit
                this.metadatas[idx] = 0;
                this.expiry[idx] = 0;
                this.entries[idx].key.deinit(allocator);
                this.entries[idx].value.deinit(allocator);
            }
            return freed;
        }

        fn compress(this: *This, now: u32, allocator: *alloc.LocalAllocator) u32 {
            const expiriesa = @Vector(8, u32){
                this.expiry[0],
                this.expiry[1],
                this.expiry[2],
                this.expiry[3],
                this.expiry[4],
                this.expiry[5],
                this.expiry[6],
                this.expiry[7],
            };

            const expiriesb = @Vector(8, u32){
                this.expiry[8],
                this.expiry[9],
                this.expiry[10],
                this.expiry[11],
                this.expiry[12],
                this.expiry[13],
                this.expiry[14],
                this.expiry[15],
            };
            const freeda = this.removeExpired(expiryClzIdx(expiriesa, now, clz_lower_vec), allocator);
            const freedb = this.removeExpired(expiryClzIdx(expiriesb, now, clz_upper_vec), allocator);
            return freeda + freedb;
        }

        // If Result.Present key is owned by caller. If Result.Absent key is consumed by SmallMap
        // if Result.Split the key is owned by caller and nothing has been changed
        fn updateOrCreate(this: *This, hash: u64, key: string.String, now: u32, la: *alloc.LocalAllocator) SmallMap.Result {
            const attempt = this.updateOrCreate0(hash, key, now);
            if (attempt != .Split) return attempt;
            if (this.compress(now, la) == 0) return .Split;
            return this.updateOrCreate(hash, key, now, la);
        }

        fn updateOrCreate0(this: *This, hash: u64, key: string.String, now: u32) SmallMap.Result {
            const maybe_idx = this.findIdxOf(hash, &key);
            if (maybe_idx) |idx| {
                if (this.expiry[idx] == 0 or this.expiry[idx] > now) {
                    return SmallMap.Result{ .Present = .{ .value = &this.entries[idx].value, .expires = &this.expiry[idx] } };
                } else {
                    return SmallMap.Result{ .Expired = .{ .value = &this.entries[idx].value, .expires = &this.expiry[idx] } };
                }
            }

            const maybe_new_idx = this.findEmptySlot();
            if (maybe_new_idx) |new_idx| {
                this.entries[new_idx].key = key;
                this.metadatas[new_idx] = present_mask | (@as(u16, @intCast(hash & hash_mask)));
                return SmallMap.Result{ .Absent = .{ .value = &this.entries[new_idx].value, .expires = &this.expiry[new_idx] } };
            }

            return .Split;
        }

        fn delete(this: *This, hash: u64, key: *const string.String, now: u32) ?SmallMap.Deleted {
            const maybe_idx = this.findIdxOf(hash, key);
            if (maybe_idx) |idx| {
                const res = SmallMap.Deleted{
                    .entry = this.entries[idx],
                    .expired = !(this.expiry[idx] == 0 or this.expiry[idx] > now),
                };
                this.expiry[idx] = 0;
                this.metadatas[idx] = 0;
                return res;
            }
            return null;
        }
    };
}

pub const SmallMap = struct {
    const bucketCount = 18;
    level: u6,
    size: u16,
    entries: [bucketCount]Bucket(),

    const This = @This();

    pub fn clear(this: *This, level: u6) void {
        for (0..bucketCount) |entry_i| {
            this.entries[entry_i].clear();
        }
        this.level = level;
        this.size = 0;
    }

    pub const Result = union(enum) {
        Present: struct { value: *Value, expires: *u32 },
        Absent: struct { value: *Value, expires: *u32 },
        Expired: struct { value: *Value, expires: *u32 },
        Split,
    };

    pub const Deleted = struct {
        entry: Entry,
        expired: bool,
    };

    fn bucketIndex(shifted_hash: u64) usize {
        const bucketIdx = shifted_hash % bucketCount;
        return bucketIdx;
    }

    // If Result.Present key is owned by caller. If Result.Absent key is consumed by SmallMap
    // if Result.Split the key is owned by caller and nothing has been changed
    pub fn updateOrCreate(this: *This, hash: u64, key: string.String, now: u32, allocator: *alloc.LocalAllocator) Result {
        const shifted_hash = hash >> this.level;
        const bucket_index = bucketIndex(shifted_hash);
        const bucket = &this.entries[bucket_index];
        return bucket.updateOrCreate(shifted_hash, key, now, allocator);
    }

    pub fn get(this: *const This, hash: u64, key: *const string.String, now: u32) ?*const Value {
        const shifted_hash = hash >> this.level;
        const bucket_index = bucketIndex(shifted_hash);
        const bucket = &this.entries[bucket_index];
        return bucket.get(shifted_hash, key, now);
    }

    pub fn delete(this: *This, hash: u64, key: *const string.String, now: u32) ?Deleted {
        const shifted_hash = hash >> this.level;
        const bucket_index = bucketIndex(shifted_hash);
        const bucket = &this.entries[bucket_index];
        return bucket.delete(shifted_hash, key, now);
    }

    fn fillFromSplit(this: *This, data: *This, bit: u16, now: u32, la: *alloc.LocalAllocator) void {
        const one: u16 = 1;
        var inserted: usize = 0;
        for (0..bucketCount) |i| {
            const bucket = &data.entries[i];
            var present = bucket.metaClzIdxFast(Bucket().present_mask | 1, Bucket().present_mask | bit);
            while (present != 0) {
                const idx = @clz(present);
                present ^= (one << 15) >> @intCast(idx);

                const entry = &bucket.entries[idx];
                inserted += 1;
                const hash = entry.key.hash();

                switch (this.updateOrCreate(hash, entry.key, now, la)) {
                    Result.Absent => |v| {
                        v.value.* = entry.value;
                        v.expires.* = bucket.expiry[idx];
                    },
                    else => unreachable,
                }
            }
        }
    }
};

const maxDictExpansions: usize = 48;
const startLevel: usize = 4;

pub const ExtendibleMap = struct {
    dict: std.atomic.Atomic(*Dict),
    max_expansions: usize,
    expansion_ptrs: [maxDictExpansions]lock.OptLock(*Dict),
    expansions: [maxDictExpansions]Dict,

    const Dict = struct {
        segments: []std.atomic.Atomic(*lock.QueueLock(SmallMap)),
        level: u64,
        copied: bool,
    };

    const This = @This();

    fn currentIdx(dict: *Dict, hash: u64) u64 {
        var level = dict.level;
        if (!dict.copied) {
            level -= 1;
        }
        const one: u64 = 1;
        const idx = hash & ((one << @intCast(level)) - 1);
        return idx;
    }

    const AcquireState = struct {
        hash: u64,
        queued: ?struct {
            slot: ?u32,
            lock: *lock.QueueLock(SmallMap),
        } = null,
        this: *This,
    };

    pub const AcquireResult = struct {
        map: *SmallMap,
        lock: *lock.QueueLock(SmallMap),
    };

    pub const AcquireMachine = state.Machine(AcquireState, AcquireResult, struct {
        const Drive = state.Drive(AcquireResult);
        pub fn drive(s: *AcquireState) Drive {
            const dict: *Dict = s.this.dict.load(std.atomic.Ordering.Acquire);
            const idx = currentIdx(dict, s.hash);

            if (s.queued) |q| {
                var locked = false;
                if (q.slot) |slot| {
                    locked = q.lock.tryDeque(slot);
                } else if (q.lock.queue()) |slot| {
                    s.queued = .{ .slot = slot, .lock = q.lock };
                } else {
                    locked = true;
                }

                if (locked) {
                    s.queued = null;
                    // Dash Algorithm 3 line 11
                    // see ReadMachine

                    const new_dict: *Dict = s.this.dict.load(std.atomic.Ordering.Acquire);
                    const new_idx = currentIdx(new_dict, s.hash);
                    const new_map_lock = dict.segments[idx].load(std.atomic.Ordering.Monotonic);

                    if (dict != new_dict or idx != new_idx or q.lock != new_map_lock) {
                        q.lock.unlock();
                        return .Incomplete;
                    }
                    return Drive{ .Complete = .{ .map = &q.lock.value, .lock = q.lock } };
                }
            } else {
                var map_lock: *lock.QueueLock(SmallMap) = dict.segments[idx].load(std.atomic.Ordering.Monotonic);
                s.queued = .{ .slot = null, .lock = map_lock };
                return drive(s);
            }
            return .Incomplete;
        }
    });

    pub const MAcquireItem = struct {
        hash: u64,
        slot: ?u32,
        lock: ?*lock.QueueLock(SmallMap),
    };

    const MAcquireState = struct {
        this: *This,
        items: usize,
        locks: []MAcquireItem,
        locks_acquired: usize,
        setup: bool = false,
    };

    fn lock_sorter(_: void, a: MAcquireItem, b: MAcquireItem) bool {
        if (a.lock) |alock| {
            if (b.lock) |block| {
                return @intFromPtr(alock) < @intFromPtr(block);
            } else {
                return true;
            }
        }
        return false;
    }

    pub const MAcquireMachine = state.Machine(MAcquireState, void, struct {
        const Drive = state.Drive(void);
        pub fn drive(s: *MAcquireState) Drive {
            if (!s.setup) {
                const dict: *Dict = s.this.dict.load(std.atomic.Ordering.Acquire);
                for (s.locks[0..s.items]) |*item| {
                    const current_idx = currentIdx(dict, item.hash);
                    item.lock = dict.segments[current_idx].load(std.atomic.Ordering.Monotonic);
                }

                // We lock the locks in asceding order to avoid any trouble with friends.
                std.sort.insertion(MAcquireItem, s.locks[0..s.items], {}, lock_sorter);
                s.setup = true;
            }

            if (s.locks[s.locks_acquired].lock == null) return Drive{ .Complete = {} };
            const old_lock = s.locks[s.locks_acquired].lock.?;

            // If old_lock == prev_lock it is already locked.
            if (s.locks_acquired > 0 and old_lock == s.locks[s.locks_acquired - 1].lock.?) {
                s.locks_acquired += 1;
                return drive(s);
            }

            var locked = false;
            if (s.locks[s.locks_acquired].slot) |slot| {
                if (old_lock.tryDeque(slot)) {
                    locked = true;
                }
            } else if (old_lock.queue()) |slot| {
                s.locks[s.locks_acquired].slot = slot;
            } else {
                locked = true;
            }

            if (locked) {
                s.locks[s.locks_acquired].slot = null;
                const dict: *Dict = s.this.dict.load(std.atomic.Ordering.Acquire);
                const old_hash = s.locks[s.locks_acquired].hash;
                const idx = currentIdx(dict, old_hash);
                const now_lock = dict.segments[idx].load(std.atomic.Ordering.Monotonic);
                if (now_lock != old_lock) {
                    // now the fun begins.

                    // first find the position to insert the new lock.
                    // for big arrays binary search could be used
                    var insert_idx: usize = 0;
                    while (lock_sorter({}, s.locks[insert_idx], MAcquireItem{ .hash = 0, .lock = now_lock, .slot = null })) : (insert_idx += 1) {}

                    // In the end remove oldlock and insert nowlock
                    if (insert_idx < s.locks_acquired) {
                        // next unlock all acquired locks after that index
                        for (insert_idx..s.locks_acquired) |i| {
                            if (i > 0 and s.locks[i - 1].lock.? == s.locks[i].lock.?) continue;
                            s.locks[i].lock.?.unlock();
                        }

                        // lock1|lock2|lock3|<oldlock>|lock4 ...
                        //        idx
                        //       Shift lock2 and lock3 up by one

                        var top = s.locks_acquired;
                        while (top > insert_idx) : (top -= 1) {
                            s.locks[top] = s.locks[top - 1];
                        }
                    } else if (insert_idx > s.locks_acquired) {
                        // lock1|<oldlock>|lock2|lock3|lock4 ...
                        //                        idx
                        //       Shift lock2 and lock3 down by one
                        //
                        // We must decrease insert idx by one because it points at the next greater element.
                        insert_idx -= 1;

                        for (s.locks_acquired..insert_idx) |i| {
                            s.locks[i] = s.locks[i + 1];
                        }
                    }
                    s.locks[insert_idx].lock = now_lock;
                    s.locks[insert_idx].hash = old_hash;
                    s.locks_acquired = @min(insert_idx, s.locks_acquired);
                    old_lock.unlock();
                    return drive(s);
                }
                s.locks_acquired += 1;
                return drive(s);
            }

            return .Incomplete;
        }
    });

    pub fn multi_acquire(this: *This, items: usize, locks: []MAcquireItem) MAcquireMachine {
        return MAcquireMachine.init(MAcquireState{
            .this = this,
            .items = items,
            .locks = locks,
            .locks_acquired = 0,
        });
    }

    // multi_get_map is based on trust me bro science.
    // If *SmallMap is not locked, stuff **will** go wrong.
    pub fn multi_get_map(this: *This, hash: u64) *SmallMap {
        const dict: *Dict = this.dict.load(std.atomic.Ordering.Acquire);
        const current_idx = currentIdx(dict, hash);
        return &dict.segments[current_idx].load(std.atomic.Ordering.Monotonic).value;
    }

    pub fn acquire(this: *This, hash: u64) AcquireMachine {
        return AcquireMachine.init(AcquireState{
            .hash = hash,
            .this = this,
        });
    }

    pub fn ReadState(comptime DepMachine: type, comptime Creator: type) type {
        return union(enum) {
            Preparing: struct {
                hash: u64,
                this: *This,
                creator: Creator,
            },
            Driving: struct {
                hash: u64,
                this: *This,
                creator: Creator,
                lock: *lock.QueueLock(SmallMap),
                read: lock.QueueLock(SmallMap).Read,
                machine: DepMachine,
            },
        };
    }

    pub fn ReadMachine(comptime DepMachine: type, comptime Creator: type, comptime Result: type) type {
        const State = ReadState(DepMachine, Creator);
        return state.Machine(State, Result, struct {
            const Drive = state.Drive(Result);
            pub fn drive(s: *State) Drive {
                switch (s.*) {
                    .Preparing => |*prep| {
                        var read_dict: *Dict = prep.this.dict.load(std.atomic.Ordering.Acquire);
                        const idx = currentIdx(read_dict, prep.hash);

                        var map_lock = read_dict.segments[idx].load(std.atomic.Ordering.Monotonic);
                        if (map_lock.startRead()) |lock_read| {

                            // Things couldve happend between calculating the index and acquiring read permission for the small map.

                            // For example it was assumed, that this read could safely be from an unlocked map, whilest splitting to a bigger dict.
                            //   This may not be the case, because between currentIdx and startRead the map could've been unlocked and finished it's split.
                            //   If this split was into the upper half of the dict we now have the wrong read permission.

                            // The other case is if it simply split.
                            // We loaded the pointer to old_low, it split into high, low, we read from low, while our key was moved to high.
                            // Therefore we need to double check.

                            // See: Dash Alogorithm 3 line 11

                            var new_read_dict = prep.this.dict.load(std.atomic.Ordering.Acquire);
                            const new_idx = currentIdx(new_read_dict, prep.hash);
                            if (new_idx != idx or
                                new_read_dict != read_dict or
                                map_lock != read_dict.segments[idx].load(std.atomic.Ordering.Monotonic))
                            {
                                return .Incomplete;
                            }

                            s.* = State{
                                .Driving = .{
                                    .hash = prep.hash,
                                    .this = prep.this,
                                    .creator = prep.creator,
                                    .read = lock_read,
                                    .machine = prep.creator.new(),
                                    .lock = map_lock,
                                },
                            };
                            return drive(s);
                        }
                        return .Incomplete;
                    },
                    .Driving => |*driving| {
                        if (driving.machine.step_drive(driving.read.data)) |result| {
                            if (driving.lock.verifyRead(driving.read)) {
                                driving.machine.deinit();
                                return Drive{ .Complete = result };
                            } else {
                                // TODO: Benchmark greedy retries
                                driving.creator.invalidate(driving.machine);
                                s.* = State{
                                    .Preparing = .{
                                        .hash = driving.hash,
                                        .this = driving.this,
                                        .creator = driving.creator,
                                    },
                                };
                                return .Incomplete;
                            }
                        }
                        return .Incomplete;
                    },
                }
            }
        });
    }

    pub fn read(this: *This, hash: u64, comptime DepMachine: type, comptime Creator: type, comptime Result: type, creator: Creator) ReadMachine(DepMachine, Creator, Result) {
        return ReadMachine(DepMachine, Creator, Result).init(ReadState(DepMachine, Creator){
            .Preparing = .{
                .hash = hash,
                .this = this,
                .creator = creator,
            },
        });
    }

    const SplitState = struct {
        this: *This,
        with: *lock.QueueLock(SmallMap),
        hash: u64,
    };

    const dict_level_zero = 4;

    pub const SplitMachine = state.Machine(SplitState, AcquireResult, struct {
        const Drive = state.Drive(AcquireResult);
        pub fn drive(s: *SplitState) Drive {
            const one: u64 = 1;
            var now: *Dict = s.this.dict.load(std.atomic.Ordering.Monotonic);

            if (!now.copied) {
                // do better things with our time than wait for a copie.
                // maybe we can bake some cake... :)
                return .Incomplete;
            }

            // test if the smallmap would fit into the dict
            if (now.level < s.with.value.level) {
                const next_level = now.level + 1;
                const next_idx = next_level - dict_level_zero;
                if (next_level > s.this.max_expansions + dict_level_zero) {
                    // TODO: yeah, no, check this before you create the machine. I know you can do this
                    unreachable;
                }

                // extend dict
                if (s.this.expansion_ptrs[next_idx].tryLock()) |l_next| {
                    var next = l_next.*;
                    var maybe_expandet: *Dict = s.this.dict.load(std.atomic.Ordering.Acquire);
                    // double checked lock
                    if (maybe_expandet == now) {
                        // the dict was not yet expandet and we have the honor to expand it
                        s.this.dict.store(next, std.atomic.Ordering.Monotonic);

                        // copy all small map references so everything stays legal
                        var copy_idx: u64 = 0;
                        const now_level: u6 = @intCast(now.level);
                        const next_zero = (one << now_level);
                        while (copy_idx < next_zero) : (copy_idx += 1) {
                            next.segments[copy_idx + next_zero].store(next.segments[copy_idx].load(std.atomic.Ordering.Monotonic), std.atomic.Ordering.Monotonic);
                        }

                        // We've copied
                        next.copied = true;
                        s.this.dict.store(next, std.atomic.Ordering.Release);

                        now = next;
                    } else {
                        if (maybe_expandet.copied) {
                            // the dict was expandet therefore the new smallmap level _must_ fit.
                            now = maybe_expandet;
                        } else {
                            // someone else is expanding, well wait...
                            s.this.expansion_ptrs[next_idx].unlock();
                            return .Incomplete;
                        }
                    }
                    s.this.expansion_ptrs[next_idx].unlock();
                } else {
                    // we need an expansion but someone else is currently expanding or something...
                    return .Incomplete;
                }
            }

            const dict_level: u6 = @intCast(now.level);
            const old_map_level = s.with.value.level - 1;
            // the mask to find the first idx of the smallmap in the dict
            const map_idx_mask = (one << @intCast(old_map_level));
            // the first idx to find the `with` map
            var idx = (s.hash & (map_idx_mask - 1)) + map_idx_mask;

            // splitting by inserting the new `with` smallmap at the right places
            while (idx < (one << dict_level)) : (idx += map_idx_mask << 1) {
                now.segments[idx].store(s.with, std.atomic.Ordering.Monotonic);
            }

            // verify that the dict didn't increase in size while we weren't looking
            // this should _almost_ never happen as the dict can only be expanded around 30 times
            const then = s.this.dict.load(std.atomic.Ordering.Monotonic);
            if (now != then) {
                // retry this operation for the full dict
                return .Incomplete;
            }
            return Drive{ .Complete = .{
                .lock = s.with,
                .map = &s.with.value,
            } };
        }
    });

    // Null indicates OOM or OOS
    pub fn split(this: *This, hash: u64, small_map: *SmallMap, allocator: *alloc.LocalAllocator) ?SplitMachine {
        var tmp: SmallMap = small_map.*;
        var second_map: *lock.QueueLock(SmallMap) = allocator.allocate(lock.QueueLock(SmallMap)) orelse {
            std.debug.print("OOM\n", .{});
            return null;
        };
        const next_level = small_map.level + 1;

        if (next_level > this.max_expansions + dict_level_zero) {
            std.debug.print("OOS\n", .{});
            // we cant expand beyond this magic
            return null;
        }

        small_map.clear(next_level);
        second_map.version.store(0, std.atomic.Ordering.Monotonic);
        second_map.value.clear(next_level);

        small_map.fillFromSplit(&tmp, 0, 0, allocator);
        var second: *SmallMap = &second_map.value;
        second.fillFromSplit(&tmp, 1, 0, allocator);

        if (second_map.queue()) |_| {
            unreachable;
        }

        return SplitMachine.init(SplitState{
            .this = this,
            .hash = hash,
            .with = second_map,
        });
    }

    pub fn setup(this: *This, max_expansions: u64, slab_allocator: std.mem.Allocator, local_allocator: *alloc.LocalAllocator) ExtendibleMapError!void {
        if (max_expansions > maxDictExpansions) {
            return ExtendibleMapError.MapExpansionLimit;
        }

        const one: u64 = 1;
        const entries: u64 = 16 * (one << @as(u6, @intCast(max_expansions + 1)));
        var backing_slab = slab_allocator.alloc(std.atomic.Atomic(*lock.QueueLock(SmallMap)), entries) catch return ExtendibleMapError.SlabAllocation;

        // setup expansions
        for (0..(max_expansions + 1)) |i| {
            this.expansions[i].copied = false;
            this.expansions[i].level = 4 + i;
            this.expansions[i].segments = backing_slab[0..(16 * (one << @intCast(i)))];
            this.expansion_ptrs[i] = lock.OptLock(*Dict).init(&this.expansions[i]);
        }
        // setup slab
        var first_map: *lock.QueueLock(SmallMap) = local_allocator.allocate(lock.QueueLock(SmallMap)) orelse return ExtendibleMapError.MapAllocation;
        first_map.value.clear(0);

        for (0..16) |i| {
            backing_slab[i].store(first_map, std.atomic.Ordering.Monotonic);
        }
        this.expansions[0].copied = true;

        this.dict = std.atomic.Atomic(*Dict).init(&this.expansions[0]);
        this.max_expansions = max_expansions;
    }
};

const ExtendibleMapError = error{
    SlabAllocation,
    MapAllocation,
    MapExpansionLimit,
};

pub fn FixedSizedQueue(comptime T: type, comptime Size: usize) type {
    const RSize = Size + 1;
    return struct {
        values: [RSize]T,
        size: usize,
        read: usize,
        write: usize,

        const This = @This();
        pub fn init() This {
            var a: [RSize]T = undefined;
            return This{ .values = a, .read = 0, .write = 0, .size = 0 };
        }

        pub fn push(this: *This, item: T) bool {
            const next_idx = (this.write + 1) % RSize;
            if (next_idx == this.read) {
                return false;
            }
            this.size += 1;
            this.values[this.write] = item;
            this.write = next_idx;
            return true;
        }

        pub fn pop(this: *This) ?T {
            if (this.read == this.write) {
                return null;
            }
            this.size -= 1;
            const current_idx = this.read;
            this.read = (this.read + 1) % RSize;
            return this.values[current_idx];
        }

        pub fn isFull(this: *This) bool {
            const next_idx = (this.write + 1) % RSize;
            return next_idx == this.read;
        }
    };
}

pub const InsertAndSplitState = struct {
    pub fn init(key: string.String, map: *ExtendibleMap, now: u32, lalloc: *alloc.LocalAllocator) @This() {
        return .{
            .time = now,
            .key = key,
            .map = map,
            .allocator = lalloc,
            .splitmachine = null,
            .acquiremachine = null,
        };
    }

    time: u32,
    key: string.String,
    map: *ExtendibleMap,
    allocator: *alloc.LocalAllocator,
    splitmachine: ?struct {
        smallmap: *lock.QueueLock(SmallMap),
        machine: ExtendibleMap.SplitMachine,
    },
    acquiremachine: ?ExtendibleMap.AcquireMachine,
};

pub const InsertAndSplitResult = struct {
    present: bool,
    value: *Value,
    expires: *u32,
    acquired: ExtendibleMap.AcquireResult,
};

pub const InsertAndSplitMachine = state.Machine(InsertAndSplitState, ?InsertAndSplitResult, struct {
    const Drive = state.Drive(?InsertAndSplitResult);
    pub fn drive(s: *InsertAndSplitState) Drive {
        if (s.acquiremachine) |*acquire| {
            if (acquire.drive()) |acquired| {
                switch (acquired.map.updateOrCreate(s.key.hash(), s.key, s.time, s.allocator)) {
                    SmallMap.Result.Present => |ptr| return Drive{ .Complete = .{
                        .present = true,
                        .value = ptr.value,
                        .expires = ptr.expires,
                        .acquired = acquired,
                    } },
                    SmallMap.Result.Absent => |ptr| return Drive{ .Complete = .{
                        .present = false,
                        .value = ptr.value,
                        .expires = ptr.expires,
                        .acquired = acquired,
                    } },
                    SmallMap.Result.Expired => |val| {
                        val.value.deinit(s.allocator);
                        return Drive{ .Complete = .{
                            .present = false,
                            .value = val.value,
                            .expires = val.expires,
                            .acquired = acquired,
                        } };
                    },
                    SmallMap.Result.Split => {
                        s.splitmachine = .{
                            .smallmap = acquired.lock,
                            .machine = s.map.split(s.key.hash(), acquired.map, s.allocator) orelse return Drive{ .Complete = null },
                        };
                        s.acquiremachine = null;
                        return drive(s);
                    },
                }
            }
            return .Incomplete;
        } else if (s.splitmachine) |*split| {
            if (split.machine.drive()) |second| {
                second.lock.unlock();
                split.smallmap.unlock();
                s.splitmachine = null;
                return drive(s);
            }
            return .Incomplete;
        } else {
            s.acquiremachine = s.map.acquire(s.key.hash());
            return drive(s);
        }
        unreachable;
    }
});

const test_threadCount = 6;

test "map.SmallMap allocator compatibility" {
    std.debug.print("\nSM Size: {}\n", .{@sizeOf(lock.OptLock(SmallMap))});
    try std.testing.expect(2 * @sizeOf(lock.OptLock(SmallMap)) < 1 << 15);
}

test "map.ExtendibleMap multi-single" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ga = try alloc.GlobalAllocator.init(50000, arena.allocator());

    const read_machine = state.DepMachine(string.String, bool, *const SmallMap, struct {
        const Drive = state.Drive(bool);
        pub fn drive(s: *string.String, dep: *const SmallMap) Drive {
            const value = dep.get(s.hash(), s, 0) orelse return Drive{ .Complete = false };
            if (value.asConstString()) |str| {
                return Drive{ .Complete = str.eql(s) };
            }
            return Drive{ .Complete = false };
        }
    });

    const TestQ = FixedSizedQueue(InsertAndSplitMachine, 100);

    var threads: [test_threadCount]std.Thread = undefined;
    var now = try std.time.Timer.start();

    for (0..test_threadCount) |thread_num| {
        threads[thread_num] = try std.Thread.spawn(.{}, struct {
            fn thread(galloc: *alloc.GlobalAllocator, worker_id: usize) void {
                const offset = 100_000_000 * worker_id;
                const changes: usize = 1_000_000;
                var lalloc = alloc.LocalAllocator.init(galloc);
                var q = TestQ.init();
                const end = (changes + offset);
                var location: usize = offset;
                var smap: ExtendibleMap = undefined;

                smap.setup(16, std.heap.page_allocator, &lalloc) catch {
                    std.debug.print("Setup failed for {}\n", .{worker_id});
                    return;
                };

                while (true) {
                    var present = false;
                    while (q.pop()) |machine| {
                        var ins_spl_machine: InsertAndSplitMachine = machine;
                        present = true;
                        if (ins_spl_machine.drive()) |value| {
                            var v = value orelse unreachable;
                            v.value.* = Value.fromString(ins_spl_machine.state.key);
                            v.acquired.lock.unlock();
                        } else {
                            _ = q.push(ins_spl_machine);
                        }
                    }
                    while (!q.isFull() and location < end) {
                        present = true;
                        _ = q.push(InsertAndSplitMachine.init(InsertAndSplitState.init(
                            string.String.fromInt(@intCast(location)),
                            &smap,
                            &lalloc,
                        )));
                        location += 1;
                    }
                    if (!present) {
                        break;
                    }
                }

                for (offset..(changes + offset)) |i| {
                    const k = string.String.fromInt(@intCast(i));
                    var reader = smap.read(
                        k.hash(),
                        read_machine,
                        state.TrivialCreator(read_machine),
                        bool,
                        state.trivialCreator(read_machine, read_machine.init(k)),
                    );
                    std.testing.expect(reader.run()) catch {
                        std.debug.print("A nice crash by {} missing {}\n", .{ worker_id, i });
                        return;
                    };
                }
            }
        }.thread, .{ &ga, thread_num });
    }

    for (threads) |thread| {
        thread.join();
    }

    const ms = now.lap() / std.time.ns_per_ms;
    std.debug.print("2Mops*{}Threads writes+reads in {}ms = {} ops/core/ms\n", .{ test_threadCount, ms, 2_000_000 / ms });
    arena.deinit();
}

test "map.ExtendibleMap multi" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ga = try alloc.GlobalAllocator.init(50000, arena.allocator());
    var la = alloc.LocalAllocator.init(&ga);
    var m: ExtendibleMap = undefined;

    try m.setup(16, std.heap.page_allocator, &la);

    const read_machine = state.DepMachine(string.String, bool, *const SmallMap, struct {
        const Drive = state.Drive(bool);
        pub fn drive(s: *string.String, dep: *const SmallMap) Drive {
            const value = dep.get(s.hash(), s, 0) orelse return Drive{ .Complete = false };
            if (value.asConstString()) |str| {
                return Drive{ .Complete = str.eql(s) };
            }
            return Drive{ .Complete = false };
        }
    });

    const TestQ = FixedSizedQueue(InsertAndSplitMachine, 100);

    var threads: [test_threadCount]std.Thread = undefined;
    var now = try std.time.Timer.start();

    for (0..test_threadCount) |thread_num| {
        threads[thread_num] = try std.Thread.spawn(.{}, struct {
            fn thread(galloc: *alloc.GlobalAllocator, smap: *ExtendibleMap, worker_id: usize) void {
                const offset = 100_000_000 * worker_id;
                const changes: usize = 1_000_000;
                var lalloc = alloc.LocalAllocator.init(galloc);
                var q = TestQ.init();
                const end = (changes + offset);
                var location: usize = offset;

                while (true) {
                    var present = false;
                    while (q.pop()) |machine| {
                        var ins_spl_machine: InsertAndSplitMachine = machine;
                        present = true;
                        if (ins_spl_machine.drive()) |value| {
                            var v = value orelse unreachable;
                            v.value.* = Value.fromString(ins_spl_machine.state.key);
                            v.acquired.lock.unlock();
                        } else {
                            _ = q.push(ins_spl_machine);
                        }
                    }
                    while (!q.isFull() and location < end) {
                        present = true;
                        _ = q.push(InsertAndSplitMachine.init(InsertAndSplitState.init(
                            string.String.fromInt(@intCast(location)),
                            smap,
                            &lalloc,
                        )));
                        location += 1;
                    }
                    if (!present) {
                        break;
                    }
                }

                for (offset..(changes + offset)) |i| {
                    const k = string.String.fromInt(@intCast(i));
                    var reader = smap.read(
                        k.hash(),
                        read_machine,
                        state.TrivialCreator(read_machine),
                        bool,
                        state.trivialCreator(read_machine, read_machine.init(k)),
                    );
                    std.testing.expect(reader.run()) catch {
                        std.debug.print("A nice crash by {} missing {}\n", .{ worker_id, i });
                        return;
                    };
                }
            }
        }.thread, .{ &ga, &m, thread_num });
    }

    for (threads) |thread| {
        thread.join();
    }

    const ms = now.lap() / std.time.ns_per_ms;
    std.debug.print("2Mops*{}Threads writes+reads in {}ms = {} ops/core/ms\n", .{ test_threadCount, ms, 2_000_000 / ms });
    arena.deinit();
}

test "map.ExtendibleMap single" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ga = try alloc.GlobalAllocator.init(10000, arena.allocator());
    var la = alloc.LocalAllocator.init(&ga);
    var map: ExtendibleMap = undefined;
    try map.setup(16, std.heap.page_allocator, &la);

    var now = try std.time.Timer.start();

    for (0..1_000_000) |i| {
        // std.debug.print("Inserting key {}\n", .{i});
        const k = string.String.fromInt(@intCast(i));
        const h = k.hash();
        while (true) {
            var acquire_machine = map.acquire(h);
            var m: ExtendibleMap.AcquireResult = acquire_machine.run();
            switch (m.map.updateOrCreate(h, k, 0, &la)) {
                SmallMap.Result.Present => unreachable,
                SmallMap.Result.Absent => |ptr| {
                    ptr.value.* = Value.fromString(k);
                    m.lock.unlock();
                    break;
                },
                SmallMap.Result.Split => {
                    var machine = map.split(h, m.map, &la) orelse unreachable;
                    var second: ExtendibleMap.AcquireResult = machine.run();
                    second.lock.unlock();
                },
                else => unreachable,
            }
            m.lock.unlock();
        }
    }

    const write_lap_time = now.lap();
    std.debug.print("1Mops writes in {}ms = {} ops / ms\n", .{ write_lap_time / std.time.ns_per_ms, 1_000_000 / (write_lap_time / std.time.ns_per_ms) });

    const read_machine = state.DepMachine(string.String, bool, *const SmallMap, struct {
        const Drive = state.Drive(bool);
        pub fn drive(s: *string.String, dep: *const SmallMap) Drive {
            const value = dep.get(s.hash(), s, 0) orelse return Drive{ .Complete = false };
            if (value.asConstString()) |str| {
                return Drive{ .Complete = str.eql(s) };
            }
            return Drive{ .Complete = false };
        }
    });

    const expect = std.testing.expect;

    for (0..1_000_000) |i| {
        const k = string.String.fromInt(@intCast(i));
        var reader = map.read(
            k.hash(),
            read_machine,
            state.TrivialCreator(read_machine),
            bool,
            state.trivialCreator(read_machine, read_machine.init(k)),
        );
        try expect(reader.run());
    }

    const read_lap_time = now.lap();
    std.debug.print("1Mops reads in {}ms = {} ops/ms\n", .{ read_lap_time / std.time.ns_per_ms, 1_000_000 / (read_lap_time / std.time.ns_per_ms) });
    arena.deinit();
}

test "map.SmallMap split" {
    const expect = std.testing.expect;
    var ga = try alloc.GlobalAllocator.init(1, std.heap.page_allocator);
    var la = alloc.LocalAllocator.init(&ga);
    var i: usize = 0;
    while (i < 1_000_000) {
        var a: SmallMap = undefined;
        a.clear(0);
        const start = i;
        while (true) : (i += 1) {
            var k = string.String.fromInt(@intCast(i));
            if (a.updateOrCreate(k.hash(), k, 0, &la) == SmallMap.Result.Split) {
                break;
            }
        }
        var b: SmallMap = undefined;
        var c: SmallMap = undefined;
        b.clear(1);
        c.clear(1);
        b.fillFromSplit(&a, 0, 0, &la);
        c.fillFromSplit(&a, 1, 0, &la);

        for (start..i) |check| {
            var k = string.String.fromInt(@intCast(check));
            expect(c.get(k.hash(), &k, 0) != null or b.get(k.hash(), &k, 0) != null) catch |err| {
                std.debug.print("Missing key: {}, hash = {}\n", .{ check, k.hash() });
                return err;
            };
        }
    }
}

test "map.SmallMap.basic" {
    const expect = std.testing.expect;
    var ga = try alloc.GlobalAllocator.init(1, std.heap.page_allocator);
    var la = alloc.LocalAllocator.init(&ga);

    var a: SmallMap = undefined;
    a.clear(0);
    const n = 304 / 2;
    const h = n / 2;

    for (0..n) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = k;
        switch (a.updateOrCreate(k.hash(), k, 0, &la)) {
            SmallMap.Result.Absent => |ptr| ptr.value.* = Value.fromString(v),
            else => unreachable,
        }
    }

    for (0..n) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        switch (a.updateOrCreate(k.hash(), k, 0, &la)) {
            SmallMap.Result.Present => |ptr| {
                const as_str = ptr.value.asString() orelse unreachable;
                try expect(as_str.eql(&k));
                ptr.value.* = Value.fromString(v);
            },
            else => unreachable,
        }
    }

    for (0..n) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        var v_ptr = a.get(k.hash(), &k, 0) orelse unreachable;
        const as_str = v_ptr.asConstString() orelse unreachable;
        try expect(as_str.eql(&v));
    }

    for (0..h) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        var entry = a.delete(k.hash(), &k, 0) orelse unreachable;
        const as_str = entry.entry.value.asString() orelse unreachable;
        try expect(as_str.eql(&v));
    }

    for (0..h) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        if (a.get(k.hash(), &k, 0)) |_| {
            unreachable;
        }
    }

    for (h..n) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        var v_ptr = a.get(k.hash(), &k, 0) orelse unreachable;
        const as_str = v_ptr.asConstString() orelse unreachable;
        try expect(as_str.eql(&v));
    }

    for (h..n) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        var entry = a.delete(k.hash(), &k, 0) orelse unreachable;
        const as_str = entry.entry.value.asString() orelse unreachable;
        try expect(as_str.eql(&v));
    }

    for (h..n) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        if (a.get(k.hash(), &k, 0)) |_| {
            unreachable;
        }
    }
}

test "map.List" {
    const expect = std.testing.expect;
    try expect(@sizeOf(*allowzero void) == @sizeOf(?*void) and @sizeOf(List) == @sizeOf(Value));

    var ga = try alloc.GlobalAllocator.init(1, std.heap.page_allocator);
    var la = alloc.LocalAllocator.init(&ga);

    var s1 = string.String.empty();
    s1.append("Hi", &la).?;

    var s2 = string.String.empty();
    s2.append("Bye", &la).?;

    var list = List.empty();

    var node1 = la.allocate(List.Node).?;
    node1.value = s1;

    var node2 = la.allocate(List.Node).?;
    node2.value = s2;

    try expect(list.len() == 0);
    list.lpush(node1);
    try expect(list.len() == 1);

    const n = list.lpop();
    try expect(list.len() == 0);
    try expect(n == node1);
    try expect(list.lpop() == null);

    list.lpush(node1);
    try expect(list.len() == 1);
    list.lpush(node2);
    try expect(list.len() == 2);

    const n2 = list.lpop();
    try expect(list.len() == 1);
    try expect(n2 == node2);
    try expect(n2.?.value.eql(&s2));

    const n1 = list.lpop();
    try expect(list.len() == 0);
    try expect(n1 == node1);
    try expect(n1.?.value.eql(&s1));
    try expect(list.lpop() == null);
}
