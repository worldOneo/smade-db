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
        const node = allocator.allocate(Node).?;
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

    fn tag(this: *This) ValueTag {
        var sms: *const [24]u8 = @ptrCast(this);
        return @enumFromInt(sms[23] & 0b11);
    }

    fn complexTag(this: *This) ?ComplexValueTag {
        if (this.tag() == ValueTag.Complex) {
            var sms: *const [24]u8 = @ptrCast(this);
            return @enumFromInt((sms[23] >> 2) & 0b11);
        }
        return null;
    }

    pub fn isPresent(this: *This) bool {
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

    pub fn asCOnstList(this: *const This) ?*const List {
        return constCast(List, asList)(this);
    }

    pub fn asList(this: *This) ?*List {
        const valueTag = this.tag();
        if (valueTag != .List) {
            return null;
        }
        return @ptrCast(this);
    }
};

pub const Entry = struct {
    metadata: u64,
    key: string.String,
    value: Value,
    pub fn init(k: string.String, v: Value) @This() {
        return .{ .key = k, .value = v };
    }
};

const smallMapEntries: usize = 1021; // a nice prime number, consider 509, 251, or 127

pub const SmallMap = struct {
    level: u8,
    size: u16,
    entries: [smallMapEntries]Entry,

    const This = @This();

    const presentMask: u64 = 1 << 63;
    const distanceMask: u64 = 0b111 << 60;
    const hashMask: u64 = (~(presentMask | distanceMask));
    const maxDist: u64 = 7;

    fn isMetaPresent(metadata: u64) bool {
        return metadata & presentMask == presentMask;
    }

    fn distanceOfMeta(metadata: u64) u64 {
        return (metadata & distanceMask) >> 60;
    }

    fn hashOfMeta(metadata: u64) u64 {
        return metadata & hashMask;
    }

    fn metaOfDistanceAndHash(hash: u64, distance: u64) u64 {
        return (hash & hashMask) | (distance << 60) | presentMask;
    }

    fn cutHash(hash: u64) u64 {
        return (hash & hashMask);
    }

    pub fn clear(this: *This, level: u8) void {
        for (0..smallMapEntries) |entry_i| {
            this.entries[entry_i].metadata = 0;
        }
        this.level = level;
        this.size = 0;
    }

    const Result = union(enum) {
        Present: *Value,
        Absent: *Value,
        Split,
    };

    // If Result.Present key is owned by caller. If Result.Absent key is consumed by SmallMap
    // if Result.Split the key is owned by caller and nothing has been changed
    pub fn updateOrCreate(this: *This, hash: u64, key: string.String) Result {
        if (this.size == @as(u16, @intCast(smallMapEntries))) {
            return .Split;
        }

        const shifted_hash = hash >> @intCast(this.level);

        const starting_pos = shifted_hash % smallMapEntries;
        var pos = starting_pos;
        var distance: u64 = 0;

        while (isMetaPresent(this.entries[pos].metadata) and distanceOfMeta(this.entries[pos].metadata) >= distance and distance <= maxDist) {
            if (hashOfMeta(this.entries[pos].metadata) == cutHash(shifted_hash) and this.entries[pos].key.eql(&key)) {
                return Result{ .Present = &this.entries[pos].value };
            }
            pos += 1;
            pos %= smallMapEntries;
            distance += 1;
        }

        if (distance > maxDist) {
            return .Split;
        }

        if (!isMetaPresent(this.entries[pos].metadata)) {
            this.entries[pos].metadata = metaOfDistanceAndHash(shifted_hash, distance);
            this.entries[pos].key = key;
            this.size += 1;
            return Result{ .Absent = &this.entries[pos].value };
        }

        // shift all later entries.
        // We need to do it 2 times to prevent corruption and OOM.

        // first pass, test if insert is possible:
        var prev_entry = this.entries[pos];
        var shift_pos = pos;
        while (isMetaPresent(prev_entry.metadata)) {
            shift_pos += 1;
            shift_pos %= smallMapEntries;

            const prev_distance = distanceOfMeta(prev_entry.metadata);
            const new_distance = prev_distance + 1;

            if (new_distance > maxDist) {
                // we know that this insert couldn't be completed
                return .Split;
            }

            prev_entry = this.entries[shift_pos];
        }

        // second pass with the knowledge, that this insert can be completed;
        prev_entry = this.entries[pos];
        shift_pos = pos;

        this.entries[pos] = Entry{
            .metadata = metaOfDistanceAndHash(shifted_hash, distance),
            .key = key,
            .value = Value.nil(),
        };

        const v_ptr = &this.entries[pos].value;

        while (isMetaPresent(prev_entry.metadata)) {
            shift_pos += 1;
            shift_pos %= smallMapEntries;

            const prev_distance = distanceOfMeta(prev_entry.metadata);
            const new_distance = prev_distance + 1;

            const tmp = this.entries[shift_pos];
            prev_entry.metadata = metaOfDistanceAndHash(hashOfMeta(prev_entry.metadata), new_distance);
            this.entries[shift_pos] = prev_entry;
            prev_entry = tmp;
        }

        this.size += 1;
        return Result{ .Absent = v_ptr };
    }

    pub fn get(this: *const This, hash: u64, key: *const string.String) ?*const Value {
        const shifted_hash = hash >> @intCast(this.level);
        const starting_pos = shifted_hash % smallMapEntries;
        var pos = starting_pos;
        var distance: u64 = 0;
        while (distance <= maxDist and
            isMetaPresent(this.entries[pos].metadata) and
            distanceOfMeta(this.entries[pos].metadata) >= distance and
            !(hashOfMeta(this.entries[pos].metadata) == cutHash(shifted_hash) and this.entries[pos].key.eql(key)))
        {
            distance += 1;
            pos += 1;
            pos %= smallMapEntries;
        }

        if (hashOfMeta(this.entries[pos].metadata) == cutHash(shifted_hash) and this.entries[pos].key.eql(key)) {
            return &this.entries[pos].value;
        }
        return null;
    }

    pub fn delete(this: *This, hash: u64, key: *const string.String) ?Entry {
        const shifted_hash = hash >> @intCast(this.level);
        const starting_pos = shifted_hash % smallMapEntries;
        var pos = starting_pos;
        var distance: u64 = 0;
        while (distance <= maxDist and
            isMetaPresent(this.entries[pos].metadata) and
            distanceOfMeta(this.entries[pos].metadata) >= distance and
            !(hashOfMeta(this.entries[pos].metadata) == cutHash(shifted_hash) and this.entries[pos].key.eql(key)))
        {
            distance += 1;
            pos += 1;
            pos %= smallMapEntries;
        }

        if (hashOfMeta(this.entries[pos].metadata) == cutHash(shifted_hash) and this.entries[pos].key.eql(key)) {
            const deleted = this.entries[pos];

            while (true) {
                var prev_pos = pos;
                pos += 1;
                pos %= smallMapEntries;
                const pos_meta = this.entries[pos].metadata;
                const pos_dist = distanceOfMeta(pos_meta);
                if (!isMetaPresent(pos_meta) or pos_dist == 0) {
                    this.entries[prev_pos].metadata = 0;
                    this.size -= 1;
                    return deleted;
                }
                this.entries[prev_pos] = this.entries[pos];
                this.entries[prev_pos].metadata = metaOfDistanceAndHash(hashOfMeta(pos_meta), pos_dist - 1);
            }
        }

        return null;
    }

    fn fillFromSplit(this: *This, data: *This, bit: u64) void {
        for (0..smallMapEntries) |i| {
            if (isMetaPresent(data.entries[i].metadata) and
                hashOfMeta(data.entries[i].metadata) & 1 == bit)
            {
                switch (this.updateOrCreate(data.entries[i].key.hash(), data.entries[i].key)) {
                    Result.Absent => |v| v.* = data.entries[i].value,
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
        if (dict.copied == false) {
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
        const Drive = state.Drive(AcquireState, AcquireResult);
        fn drive(s: AcquireState) Drive {
            const dict: *Dict = s.this.dict.load(std.atomic.Ordering.Acquire);
            const idx = currentIdx(dict, s.hash);
            var map_lock = dict.segments[idx].load(std.atomic.Ordering.Monotonic);
            if (map_lock.tryLock()) |map| {
                // Dash Algorithm 3 line 11
                // see ReadMachine

                const new_dict: *Dict = s.this.dict.load(std.atomic.Ordering.Acquire);
                const new_idx = currentIdx(dict, s.hash);
                const new_map_lock = dict.segments[idx].load(std.atomic.Ordering.Monotonic);

                if (dict != new_dict or idx != new_idx or map_lock != new_map_lock) {
                    map_lock.unlock();
                    return Drive{ .Incomplete = s };
                }
                return Drive{ .Complete = .{ .map = map, .lock = map_lock } };
            }
            return Drive{ .Incomplete = s };
        }
    }.drive);

    pub fn acquire(this: *This, hash: u64) AcquireMachine {
        return AcquireMachine.init(AcquireState{
            .hash = hash,
            .this = this,
        });
    }

    pub fn release(this: *This, hash: u64) void {
        var dict = this.dict.value; // this is fine because we have locked the hash
        var map = dict[hash % dict.len].load(std.atomic.Ordering.Monotonic);
        map.unlock();
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
            const Drive = state.Drive(State, Result);
            pub fn drive(s: State) Drive {
                switch (s) {
                    State.Preparing => |const_prep| {
                        var prep = const_prep;

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
                                return Drive{ .Incomplete = s };
                            }

                            return drive(State{
                                .Driving = .{
                                    .hash = prep.hash,
                                    .this = prep.this,
                                    .creator = prep.creator,
                                    .read = lock_read,
                                    .machine = prep.creator.new(),
                                    .lock = map_lock,
                                },
                            });
                        }
                        return Drive{ .Incomplete = s };
                    },
                    State.Driving => |const_driving| {
                        var driving = const_driving;
                        if (driving.machine.step_drive(driving.read.data)) |result| {
                            if (driving.lock.verifyRead(driving.read)) {
                                return Drive{ .Complete = result };
                            } else {
                                // TODO: Benchmark greedy retries
                                return Drive{ .Incomplete = State{
                                    .Preparing = .{
                                        .hash = driving.hash,
                                        .this = driving.this,
                                        .creator = driving.creator,
                                    },
                                } };
                            }
                        }

                        return Drive{ .Incomplete = State{
                            .Driving = .{
                                .hash = driving.hash,
                                .this = driving.this,
                                .creator = driving.creator,
                                .read = driving.read,
                                .machine = driving.machine,
                                .lock = driving.lock,
                            },
                        } };
                    },
                }
            }
        }.drive);
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

    pub const SplitMachine = state.Machine(SplitState, AcquireResult, struct {
        const Drive = state.Drive(SplitState, AcquireResult);
        pub fn drive(s: SplitState) Drive {
            const one: u64 = 1;
            var now: *Dict = s.this.dict.load(std.atomic.Ordering.Monotonic);

            if (!now.copied) {
                // do better things with our time than wait for a copie.
                // maybe we can bake some cake... :)
                return Drive{ .Incomplete = s };
            }

            // test if the smallmap would fit into the dict
            if (now.level < s.with.value.level) {
                const next_level = now.level + 1;
                if (next_level > s.this.max_expansions) {
                    // TODO: yeah, no, check this before you create the machine. I know you can do this
                    unreachable;
                }

                // extend dict
                if (s.this.expansion_ptrs[next_level].tryLock()) |l_next| {
                    var next = l_next.*;
                    var maybe_expandet: *Dict = s.this.dict.load(std.atomic.Ordering.Acquire);
                    // double checked lock
                    if (maybe_expandet == now) {
                        // the dict was not yet expandet and we have the honor to expand it
                        s.this.dict.store(next, std.atomic.Ordering.Monotonic);

                        // copy all small map references so everything stays legal
                        var copy_idx: u64 = 0;
                        const now_level: u6 = @intCast(now.level);
                        while (copy_idx < (one << now_level)) : (copy_idx += 1) {
                            next.segments[copy_idx + (one << now_level)].store(next.segments[copy_idx].load(std.atomic.Ordering.Monotonic), std.atomic.Ordering.Monotonic);
                        }

                        // We've copied
                        now.copied = true;
                        s.this.dict.store(next, std.atomic.Ordering.Release);

                        now = next;
                    } else {
                        if (maybe_expandet.copied) {
                            // the dict was expandet therefore the new smallmap level _must_ fit.
                            now = maybe_expandet;
                        } else {
                            // someone else is expanding, well wait...
                            s.this.expansion_ptrs[next_level].unlock();
                            return Drive{ .Incomplete = s };
                        }
                    }
                    s.this.expansion_ptrs[next_level].unlock();
                } else {
                    // we need an expansion but someone else is currently expanding or something...
                    return Drive{ .Incomplete = s };
                }
            }

            const dict_level: u6 = @intCast(now.level);
            // the mask to find the first idx of the smallmap in the dict
            const map_idx_mask = (one << @intCast(s.with.value.level));
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
                return Drive{ .Incomplete = s };
            }
            return Drive{ .Complete = .{
                .lock = s.with,
                .map = &s.with.value,
            } };
        }
    }.drive);

    // Null indicates OOM or OOS
    pub fn split(this: *This, hash: u64, small_map: *SmallMap, allocator: *alloc.LocalAllocator) ?SplitMachine {
        var tmp: SmallMap = small_map.*;
        var second_map: *lock.OptLock(SmallMap) = allocator.allocate(lock.OptLock(SmallMap)).?;
        const next_level = small_map.level + 1;

        if (next_level > this.max_expansions) {
            // we cant expand beyond this magic
            return null;
        }

        small_map.clear(small_map.level + 1);
        second_map.* = lock.OptLock(SmallMap).init(small_map.*);
        small_map.fillFromSplit(&tmp, 0);
        second_map.value.fillFromSplit(&tmp, 1);
        while (second_map.tryLock() == null) {
            // this isnt bussy as tryLock is uncontendet
        }
        return SplitMachine.init(SplitState{
            .this = this,
            .hash = hash,
            .with = second_map,
        });
    }

    pub fn init(max_expansions: u64, slab_allocator: std.mem.Allocator, local_allocator: *alloc.LocalAllocator) ExtendibleMapError!This {
        if (max_expansions > maxDictExpansions) {
            return ExtendibleMapError.MapExpansionLimit;
        }

        const one: u64 = 1;
        const entries: u64 = 16 * (one << @as(u6, @intCast(max_expansions)));
        var backing_slab = slab_allocator.alloc(std.atomic.Atomic(*lock.OptLock(SmallMap)), entries) catch return ExtendibleMapError.SlabAllocation;
        var expansions: [maxDictExpansions]Dict = undefined;
        var expansion_ptrs: [maxDictExpansions]lock.OptLock(*Dict) = undefined;

        // setup expansions
        for (0..max_expansions) |i| {
            expansions[i].copied = false;
            expansions[i].level = 4 + i;
            expansions[i].segments = backing_slab[0..(16 * (one << @intCast(i)))];
            expansion_ptrs[i] = lock.OptLock(*Dict).init(&expansions[i]);
        }

        // setup slab
        var first_map: *lock.OptLock(SmallMap) = local_allocator.allocate(lock.OptLock(SmallMap)) orelse return ExtendibleMapError.MapAllocation;
        first_map.value.clear(0);

        for (0..16) |i| {
            backing_slab[i].store(first_map, std.atomic.Ordering.Monotonic);
        }

        return This{
            .dict = std.atomic.Atomic(*Dict).init(&expansions[0]),
            .expansions = expansions,
            .expansion_ptrs = expansion_ptrs,
            .max_expansions = max_expansions,
        };
    }
};

const ExtendibleMapError = error{
    SlabAllocation,
    MapAllocation,
    MapExpansionLimit,
};

test "map.ExtendibleMap single" {
    var ga = try alloc.GlobalAllocator.init(1000, std.heap.page_allocator);
    var la = alloc.LocalAllocator.init(&ga);
    var map = try ExtendibleMap.init(16, std.heap.page_allocator, &la);

    for (0..1_000_000) |i| {
        const k = string.String.fromInt(@intCast(i));
        const h = k.hash();
        while (true) {
            var acquire_machine = map.acquire(h);
            var m: ExtendibleMap.AcquireResult = acquire_machine.run();
            switch (m.map.updateOrCreate(h, k)) {
                SmallMap.Result.Present => unreachable,
                SmallMap.Result.Absent => |ptr| ptr.* = Value.fromString(k),
                SmallMap.Result.Split => {
                    var machine = map.split(h, m.map, &la) orelse unreachable;
                    var second: ExtendibleMap.AcquireResult = machine.run();
                    second.lock.unlock();
                },
            }
            m.lock.unlock();
        }
    }

    const read_machine = state.DepMachine(string.String, bool, *const SmallMap, struct {
        const Drive = state.Drive(string.String, bool);
        pub fn drive(s: string.String, dep: *const SmallMap) Drive {
            const value = dep.get(s.hash(), &s) orelse return Drive{ .Complete = false };
            if (value.asConstString()) |str| {
                return Drive{ .Complete = str.eql(&s) };
            }
            return Drive{ .Complete = false };
        }
    }.drive);

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
}

test "map.SmallMap.basic" {
    const expect = std.testing.expect;

    var a: SmallMap = undefined;
    a.clear(0);

    for (0..100) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = k;
        switch (a.updateOrCreate(k.hash(), k)) {
            SmallMap.Result.Absent => |ptr| ptr.* = Value.fromString(v),
            else => unreachable,
        }
    }

    for (0..100) |ui| {
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

    for (0..100) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        var v_ptr = a.get(k.hash(), &k) orelse unreachable;
        const as_str = v_ptr.asConstString() orelse unreachable;
        try expect(as_str.eql(&v));
    }

    for (0..50) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        var entry = a.delete(k.hash(), &k) orelse unreachable;
        const as_str = entry.value.asString() orelse unreachable;
        try expect(as_str.eql(&v));
    }

    for (0..50) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        if (a.get(k.hash(), &k)) |_| {
            unreachable;
        }
    }

    for (50..100) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        var v_ptr = a.get(k.hash(), &k) orelse unreachable;
        const as_str = v_ptr.asConstString() orelse unreachable;
        try expect(as_str.eql(&v));
    }

    for (50..100) |ui| {
        const i: i64 = @intCast(ui);
        const k = string.String.fromInt(i);
        const v = string.String.fromInt(i + 1);
        var entry = a.delete(k.hash(), &k) orelse unreachable;
        const as_str = entry.value.asString() orelse unreachable;
        try expect(as_str.eql(&v));
    }

    for (50..100) |ui| {
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
