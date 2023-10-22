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

    pub fn nil() This {
        var inner = [3]usize{ 0, 0, 0 };
        var sms = @as(*[24]u8, @ptrCast(&inner));
        sms[23] = 0b111;
        const value = This{ .value = inner };
        return value;
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
    }
};

pub const Entry = struct {
    key: string.String,
    value: Value,
    pub fn init(k: string.String, v: Value) @This() {
        return .{ .key = k, .value = v };
    }
};

const smallMapEntries: usize = 601; // a nice prime which fits into one allocator page, consider 509, 251, or 127

pub const SmallMap = struct {
    level: u8,
    size: u16,
    free_idx_count: usize,
    free_idx: [smallMapEntries]u16,
    metadata: [smallMapEntries]u32,
    entries: [smallMapEntries]Entry,

    const This = @This();

    const presentMask: u32 = 1 << 31;
    const distanceMask: u32 = 0b1111 << 27;
    const idxMask: u32 = 0b1111111111 << 17;
    const hashMask: u32 = (~(presentMask | distanceMask | idxMask));
    const maxDist: u32 = 15;

    fn isMetaPresent(metadata: u64) bool {
        return metadata & presentMask == presentMask;
    }

    fn distanceOfMeta(metadata: u32) u32 {
        return (metadata & distanceMask) >> 27;
    }

    fn hashOfMeta(metadata: u32) u64 {
        return @intCast(metadata & hashMask);
    }

    fn metaOfHashDistanceIndex(hash: u64, distance: u32, idx: u32) u32 {
        return @as(u32, @intCast(cutHash(hash))) | (distance << 27) | (idx << 17) | presentMask;
    }

    fn idxOfMeta(metadata: u32) usize {
        return @intCast((metadata & idxMask) >> 17);
    }

    fn cutHash(hash: u64) u64 {
        return (hash & hashMask);
    }

    pub fn clear(this: *This, level: u8) void {
        for (0..smallMapEntries) |entry_i| {
            this.metadata[entry_i] = 0;
        }
        for (0..smallMapEntries) |i| {
            this.free_idx[i] = @intCast(smallMapEntries - 1 - i);
        }
        this.free_idx_count = smallMapEntries;
        this.level = level;
        this.size = 0;
    }

    const Result = union(enum) {
        Present: *Value,
        Absent: *Value,
        Split,
    };

    // leading zeroes = index
    const shifts_clz_vec_a = @Vector(8, u32){ 31, 30, 29, 28, 27, 26, 25, 24 };
    const shifts_clz_vec_b = @Vector(8, u32){ 23, 22, 21, 20, 19, 18, 17, 16 };
    const clz_vec_a = @as(@Vector(8, u32), @splat(1)) << shifts_clz_vec_a;
    const clz_vec_b = @as(@Vector(8, u32), @splat(1)) << shifts_clz_vec_b;

    const hash_mask: @Vector(8, u32) = @splat(hashMask);
    const zeroes: @Vector(8, u32) = @splat(0);

    fn toClzIdxFast(this: *const This, hash: u64, comptime part: usize) u32 {
        // a bit of SIMD to find the first indexes with a matching hash

        const offset_start = if (part == 0) 0 else 8;
        const clz_vec = if (part == 0) clz_vec_a else clz_vec_b;
        const shifted_hash_vec: @Vector(8, u32) = @splat(@intCast(cutHash(hash)));

        const starting_pos = hash % smallMapEntries + offset_start;

        const meta_vec = if (starting_pos + 7 >= smallMapEntries) @Vector(8, u32){
            this.metadata[(starting_pos + 0) % smallMapEntries],
            this.metadata[(starting_pos + 1) % smallMapEntries],
            this.metadata[(starting_pos + 2) % smallMapEntries],
            this.metadata[(starting_pos + 3) % smallMapEntries],
            this.metadata[(starting_pos + 4) % smallMapEntries],
            this.metadata[(starting_pos + 5) % smallMapEntries],
            this.metadata[(starting_pos + 6) % smallMapEntries],
            this.metadata[(starting_pos + 7) % smallMapEntries],
        } else @Vector(8, u32){
            // fastpath no div (branch vs 8divs, but branch is ez to predict)
            this.metadata[starting_pos + 0],
            this.metadata[starting_pos + 1],
            this.metadata[starting_pos + 2],
            this.metadata[starting_pos + 3],
            this.metadata[starting_pos + 4],
            this.metadata[starting_pos + 5],
            this.metadata[starting_pos + 6],
            this.metadata[starting_pos + 7],
        };
        const hash_meta_vec = meta_vec & hash_mask;
        const hash_eq = hash_meta_vec == shifted_hash_vec;
        const clz_idxs = @select(u32, hash_eq, clz_vec, zeroes);
        const idxes = @reduce(.Or, clz_idxs);
        return idxes;
    }

    fn findIdxOf(this: *const This, shifted_hash: u64, key: *const string.String) ?usize {
        const one: u32 = 1;
        const starting_pos = shifted_hash % smallMapEntries;

        var clz_access = this.toClzIdxFast(shifted_hash, 0);
        while (clz_access != 0) {
            const idx: u32 = @clz(clz_access); // get set bit
            clz_access ^= (one << 31) >> @intCast(idx); // unset bit
            const meta_idx = (starting_pos + idx) % smallMapEntries;
            if (this.entries[idxOfMeta(this.metadata[meta_idx])].key.eql(key)) {
                return meta_idx;
            }
        }

        clz_access = this.toClzIdxFast(shifted_hash, 1);
        while (clz_access != 0) {
            const idx: u32 = @clz(clz_access); // get set bit
            clz_access ^= (one << 31) >> @intCast(idx); // unset bit
            const meta_idx = (starting_pos + idx) % smallMapEntries;
            if (this.entries[idxOfMeta(this.metadata[meta_idx])].key.eql(key)) {
                return meta_idx;
            }
        }
        return null;
    }

    // If Result.Present key is owned by caller. If Result.Absent key is consumed by SmallMap
    // if Result.Split the key is owned by caller and nothing has been changed
    pub fn updateOrCreate(this: *This, hash: u64, key: string.String) Result {
        if (this.size == @as(u16, @intCast(smallMapEntries - (smallMapEntries / 25)))) {
            // - smallMapEntries / 25 is a small buffer to avoid very long runs on insert
            return .Split;
        }
        const shifted_hash = hash >> @intCast(this.level);

        if (this.findIdxOf(shifted_hash, &key)) |idx| {
            return Result{ .Present = &this.entries[idxOfMeta(this.metadata[idx])].value };
        }

        var pos = shifted_hash % smallMapEntries;
        var distance: u32 = 0;
        while (isMetaPresent(this.metadata[pos]) and distanceOfMeta(this.metadata[pos]) >= distance and distance <= maxDist) {
            pos += 1;
            pos %= smallMapEntries;
            distance += 1;
        }

        if (distance > maxDist) {
            return .Split;
        }

        if (!isMetaPresent(this.metadata[pos])) {
            const insert_idx = this.free_idx[this.free_idx_count - 1];
            this.free_idx_count -= 1;
            this.metadata[pos] = metaOfHashDistanceIndex(
                shifted_hash,
                distance,
                @intCast(insert_idx),
            );
            this.entries[insert_idx].key = key;
            this.size += 1;
            return Result{ .Absent = &this.entries[insert_idx].value };
        }

        // shift all later entries.
        // We need to do it 2 times to prevent corruption and OOM.

        // first pass, test if insert is possible:
        var prev_entry = this.metadata[pos];
        var shift_pos = pos;
        while (isMetaPresent(prev_entry)) {
            shift_pos += 1;
            shift_pos %= smallMapEntries;

            const prev_distance = distanceOfMeta(prev_entry);
            const new_distance = prev_distance + 1;

            if (new_distance > maxDist) {
                // we know that this insert couldn't be completed
                return .Split;
            }

            prev_entry = this.metadata[shift_pos];
        }

        // second pass with the knowledge, that this insert can be completed;
        prev_entry = this.metadata[pos];
        shift_pos = pos;

        const insert_idx = this.free_idx[this.free_idx_count - 1];
        this.free_idx_count -= 1;
        this.metadata[pos] = metaOfHashDistanceIndex(
            shifted_hash,
            distance,
            @intCast(insert_idx),
        );
        this.entries[@intCast(insert_idx)] = Entry{
            .key = key,
            .value = Value.nil(),
        };

        const v_ptr = &this.entries[@intCast(insert_idx)].value;

        while (isMetaPresent(prev_entry)) {
            shift_pos += 1;
            shift_pos %= smallMapEntries;

            const prev_distance = distanceOfMeta(prev_entry);
            const new_distance = prev_distance + 1;

            const tmp = this.metadata[shift_pos];
            this.metadata[shift_pos] = metaOfHashDistanceIndex(
                hashOfMeta(prev_entry),
                new_distance,
                @intCast(idxOfMeta(prev_entry)),
            );
            prev_entry = tmp;
        }

        this.size += 1;
        return Result{ .Absent = v_ptr };
    }

    pub fn get(this: *const This, hash: u64, key: *const string.String) ?*const Value {
        const shifted_hash = hash >> @intCast(this.level);
        if (this.findIdxOf(shifted_hash, key)) |idx| {
            return &this.entries[idxOfMeta(this.metadata[idx])].value;
        }
        return null;
    }

    pub fn delete(this: *This, hash: u64, key: *const string.String) ?Entry {
        const shifted_hash = hash >> @intCast(this.level);
        if (this.findIdxOf(shifted_hash, key)) |idx| {
            const metadata = this.metadata[idx];
            if (hashOfMeta(metadata) == cutHash(shifted_hash) and
                this.entries[idxOfMeta(metadata)].key.eql(key))
            {
                const deleted = this.entries[idxOfMeta(metadata)];

                var pos: usize = @intCast(idx);
                while (true) {
                    var prev_pos = pos;
                    pos += 1;
                    pos %= smallMapEntries;
                    const pos_meta = this.metadata[pos];
                    const pos_dist = distanceOfMeta(pos_meta);

                    if (!isMetaPresent(pos_meta) or pos_dist == 0) {
                        this.free_idx[this.free_idx_count] = @intCast(idxOfMeta(this.metadata[prev_pos]));
                        this.free_idx_count += 1;

                        this.metadata[prev_pos] = 0;
                        this.size -= 1;
                        return deleted;
                    }

                    this.metadata[prev_pos] = this.metadata[pos];
                    this.metadata[prev_pos] = metaOfHashDistanceIndex(
                        hashOfMeta(pos_meta),
                        pos_dist - 1,
                        @intCast(idxOfMeta(pos_meta)),
                    );
                }
            }
        }

        return null;
    }

    fn fillFromSplit(this: *This, data: *This, bit: u64) void {
        for (0..smallMapEntries) |i| {
            const meta = data.metadata[i];
            if (isMetaPresent(meta) and
                hashOfMeta(meta) & 1 == bit)
            {
                const idx = idxOfMeta(meta);
                switch (this.updateOrCreate(data.entries[idx].key.hash(), data.entries[idx].key)) {
                    Result.Absent => |v| v.* = data.entries[idx].value,
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
        segments: []std.atomic.Atomic(*lock.OptLock(SmallMap)),
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
        this: *This,
    };

    pub const AcquireResult = struct {
        map: *SmallMap,
        lock: *lock.OptLock(SmallMap),
    };

    pub const AcquireMachine = state.Machine(AcquireState, AcquireResult, struct {
        const Drive = state.Drive(AcquireResult);
        pub fn drive(s: *AcquireState) Drive {
            const dict: *Dict = s.this.dict.load(std.atomic.Ordering.Acquire);
            const idx = currentIdx(dict, s.hash);
            var map_lock: *lock.OptLock(SmallMap) = dict.segments[idx].load(std.atomic.Ordering.Monotonic);
            if (map_lock.tryLock()) |map| {
                // Dash Algorithm 3 line 11
                // see ReadMachine

                const new_dict: *Dict = s.this.dict.load(std.atomic.Ordering.Acquire);
                const new_idx = currentIdx(new_dict, s.hash);
                const new_map_lock = dict.segments[idx].load(std.atomic.Ordering.Monotonic);

                if (dict != new_dict or idx != new_idx or map_lock != new_map_lock) {
                    map_lock.unlock();
                    return .Incomplete;
                }
                return Drive{ .Complete = .{ .map = map, .lock = map_lock } };
            }
            return .Incomplete;
        }
    });

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
                lock: *lock.OptLock(SmallMap),
                read: lock.OptLock(SmallMap).Read,
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
        with: *lock.OptLock(SmallMap),
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
        var second_map: *lock.OptLock(SmallMap) = allocator.allocate(lock.OptLock(SmallMap)) orelse {
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

        small_map.fillFromSplit(&tmp, 0);
        var second: *SmallMap = &second_map.value;
        second.fillFromSplit(&tmp, 1);
        while (second_map.tryLock() == null) {
            // this isn't bussy as tryLock is uncontendet
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
        var backing_slab = slab_allocator.alloc(std.atomic.Atomic(*lock.OptLock(SmallMap)), entries) catch return ExtendibleMapError.SlabAllocation;

        // setup expansions
        for (0..(max_expansions + 1)) |i| {
            this.expansions[i].copied = false;
            this.expansions[i].level = 4 + i;
            this.expansions[i].segments = backing_slab[0..(16 * (one << @intCast(i)))];
            this.expansion_ptrs[i] = lock.OptLock(*Dict).init(&this.expansions[i]);
        }
        // setup slab
        var first_map: *lock.OptLock(SmallMap) = local_allocator.allocate(lock.OptLock(SmallMap)) orelse return ExtendibleMapError.MapAllocation;
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
    pub fn init(key: string.String, map: *ExtendibleMap, lalloc: *alloc.LocalAllocator) @This() {
        return .{
            .key = key,
            .map = map,
            .allocator = lalloc,
            .splitmachine = null,
            .acquiremachine = null,
        };
    }

    key: string.String,
    map: *ExtendibleMap,
    allocator: *alloc.LocalAllocator,
    splitmachine: ?struct {
        smallmap: *lock.OptLock(SmallMap),
        machine: ExtendibleMap.SplitMachine,
    },
    acquiremachine: ?ExtendibleMap.AcquireMachine,
};

pub const InsertAndSplitResult = struct {
    present: bool,
    value: *Value,
    acquired: ExtendibleMap.AcquireResult,
};

pub const InsertAndSplitMachine = state.Machine(InsertAndSplitState, ?InsertAndSplitResult, struct {
    const Drive = state.Drive(?InsertAndSplitResult);
    pub fn drive(s: *InsertAndSplitState) Drive {
        if (s.acquiremachine) |*acquire| {
            if (acquire.drive()) |acquired| {
                switch (acquired.map.updateOrCreate(s.key.hash(), s.key)) {
                    SmallMap.Result.Present => |ptr| return Drive{ .Complete = .{
                        .present = true,
                        .value = ptr,
                        .acquired = acquired,
                    } },
                    SmallMap.Result.Absent => |ptr| return Drive{ .Complete = .{
                        .present = false,
                        .value = ptr,
                        .acquired = acquired,
                    } },
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

test "map.ExtendibleMap multi-single" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ga = try alloc.GlobalAllocator.init(50000, arena.allocator());

    const read_machine = state.DepMachine(string.String, bool, *const SmallMap, struct {
        const Drive = state.Drive(bool);
        pub fn drive(s: *string.String, dep: *const SmallMap) Drive {
            const value = dep.get(s.hash(), s) orelse return Drive{ .Complete = false };
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
            const value = dep.get(s.hash(), s) orelse return Drive{ .Complete = false };
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
            switch (m.map.updateOrCreate(h, k)) {
                SmallMap.Result.Present => unreachable,
                SmallMap.Result.Absent => |ptr| {
                    ptr.* = Value.fromString(k);
                    m.lock.unlock();
                    break;
                },
                SmallMap.Result.Split => {
                    var machine = map.split(h, m.map, &la) orelse unreachable;
                    var second: ExtendibleMap.AcquireResult = machine.run();
                    second.lock.unlock();
                },
            }
            m.lock.unlock();
        }
    }

    const write_lap_time = now.lap();
    std.debug.print("1Mops writes in {}ms = {} ops / ms\n", .{ write_lap_time / std.time.ns_per_ms, 1_000_000 / (write_lap_time / std.time.ns_per_ms) });

    const read_machine = state.DepMachine(string.String, bool, *const SmallMap, struct {
        const Drive = state.Drive(bool);
        pub fn drive(s: *string.String, dep: *const SmallMap) Drive {
            const value = dep.get(s.hash(), s) orelse return Drive{ .Complete = false };
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

    var i: usize = 0;
    while (i < 1_000_000) {
        var a: SmallMap = undefined;
        a.clear(0);
        const start = i;
        while (true) : (i += 1) {
            var k = string.String.fromInt(@intCast(i));
            if (a.updateOrCreate(k.hash(), k) == SmallMap.Result.Split) {
                break;
            }
        }
        var b: SmallMap = undefined;
        b.clear(1);
        var c: SmallMap = undefined;
        c.clear(1);
        b.fillFromSplit(&a, 0);
        c.fillFromSplit(&a, 1);

        for (start..i) |check| {
            var k = string.String.fromInt(@intCast(check));
            expect(c.get(k.hash(), &k) != null or b.get(k.hash(), &k) != null) catch |err| {
                std.debug.print("Missing key: {}, hash = {}\n", .{ check, k.hash() });
                return err;
            };
        }
    }
}

test "map.SmallMap.basic" {
    const expect = std.testing.expect;

    var a: SmallMap = undefined;
    a.clear(0);

    for (0..300) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = k;
        switch (a.updateOrCreate(k.hash(), k)) {
            SmallMap.Result.Absent => |ptr| ptr.* = Value.fromString(v),
            else => unreachable,
        }
    }

    for (0..300) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        switch (a.updateOrCreate(k.hash(), k)) {
            SmallMap.Result.Present => |ptr| {
                const as_str = ptr.asString() orelse unreachable;
                try expect(as_str.eql(&k));
                ptr.* = Value.fromString(v);
            },
            else => unreachable,
        }
    }

    for (0..300) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        var v_ptr = a.get(k.hash(), &k) orelse unreachable;
        const as_str = v_ptr.asConstString() orelse unreachable;
        try expect(as_str.eql(&v));
    }

    for (0..150) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        var entry = a.delete(k.hash(), &k) orelse unreachable;
        const as_str = entry.value.asString() orelse unreachable;
        try expect(as_str.eql(&v));
    }

    for (0..150) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        if (a.get(k.hash(), &k)) |_| {
            unreachable;
        }
    }

    for (150..300) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        var v_ptr = a.get(k.hash(), &k) orelse unreachable;
        const as_str = v_ptr.asConstString() orelse unreachable;
        try expect(as_str.eql(&v));
    }

    for (150..300) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        var entry = a.delete(k.hash(), &k) orelse unreachable;
        const as_str = entry.value.asString() orelse unreachable;
        try expect(as_str.eql(&v));
    }

    for (150..300) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        if (a.get(k.hash(), &k)) |_| {
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
