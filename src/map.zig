const std = @import("std");
const string = @import("./string.zig");
const alloc = @import("./alloc.zig");

const ValueTag = enum(usize) {
    LargeString = 0b00,
    SmallString = 0b01,
    List = 0b10,
    Complex = 0b11,
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

const Value = struct {
    value: [3]usize,

    const This = @This();
    fn tag(this: *This) ValueTag {
        var sms: *const [24]u8 = @ptrCast(this);
        return @enumFromInt(sms.data[23] & 0b11);
    }

    pub fn asString(this: *This) ?*string.String {
        const valueTag = this.tag();
        if (valueTag == .LargeString or valueTag == .SmallString) {
            return @ptrCast(this);
        }
        return null;
    }

    pub fn fromString(str: string.String) Value {
        return .{ .value = @as([3]usize, @ptrCast(&str)).* };
    }

    pub fn asList(this: *This) ?*List {
        const valueTag = this.tag();
        if (valueTag != .List) {
            return null;
        }
        return @ptrCast(this);
    }
};

const Entry = struct {
    metadata: u64,
    key: string.String,
    value: Value,
    pub fn init(k: string.String, v: Value) @This() {
        return .{ .key = k, .value = v };
    }
};

const smallMapEntries: usize = 131; // a nice prime number

const SmallMap = struct {
    entries: [smallMapEntries]Entry,
    level: u8,

    const This = @This();

    const presentMask: u64 = 1 << 63;
    const distanceMask: u64 = 0b111 < 60;
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
    }

    const SplitEntry = struct {
        k: string.String,
        v: ?Value,
        v_ptr: ?*Value,
    };

    const Result = union(enum) {
        Present: *Value,
        Absent: *Value,
        Split: SplitEntry,
    };

    pub fn updateOrCreate(this: *This, hash: u64, key: string.String) Result {
        const shifted_hash = hash >> this.level;
        const starting_pos = shifted_hash % smallMapEntries;
        var pos = starting_pos;
        var distance: u64 = 0;

        while (isMetaPresent(this.entries[pos].metadata) and distanceOfMeta(this.entries[pos].metadata) >= distance and distance <= maxDist) {
            if (hashOfMeta(this.entries[pos].metadata) == cutHash(shifted_hash) and this.entries[pos].key.eql(key)) {
                return Result{ .Present = &this.entries[pos].value };
            }
            pos += 1;
            pos %= smallMapEntries;
            distance += 1;
        }

        if (distance > maxDist) {
            return Result{ .Split = .{ .k = key, .v = null, .v_ptr = null } };
        }

        if (!isMetaPresent(this.entries[pos].metadata)) {
            this.entries[pos].metadata = metaOfDistanceAndHash(shifted_hash, distance);
            this.entries[pos].key = key;
            return Result{ .Absent = &this.entries[pos].value };
        }

        var prev_entry = this.entries[pos];
        var shift_pos = pos;
        this.entries[pos] = Entry{
            .metadata = metaOfDistanceAndHash(shifted_hash, distance),
            .key = key,
            .value = Value.fromString(string.String.empty()),
        };

        const v_ptr = &this.entries[pos].value;

        while (isMetaPresent(prev_entry.metadata)) {
            shift_pos += 1;
            shift_pos %= 131;

            const prev_distance = distanceOfMeta(prev_entry.metadata);
            const new_distance = prev_distance + 1;

            if (new_distance > maxDist) {
                return Result{ .Split = .{ .k = prev_entry.key, .v = prev_entry.value, .v_ptr = v_ptr } };
            }

            const tmp = this.entries[shift_pos];
            prev_entry.metadata = metaOfDistanceAndHash(hashOfMeta(prev_entry.metadata), new_distance);
            this.entries[shift_pos] = prev_entry;
            prev_entry = tmp;
        }

        return Result{ .Absent = v_ptr };
    }

    pub fn get(this: *This, hash: u64, key: string.String) ?*Value {
        const shifted_hash = hash >> this.level;
        const starting_pos = shifted_hash % smallMapEntries;
        var pos = starting_pos;
        var distance: u64 = 0;
        while (distance <= maxDist and
            isMetaPresent(this.entries[pos].metadata) and
            distanceOfMeta(this.entries[pos].metadata) and
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

    pub fn delete(this: *This, hash: u64, key: string.String) ?Entry {
        const shifted_hash = hash >> this.level;
        const starting_pos = shifted_hash % smallMapEntries;
        var pos = starting_pos;
        var distance: u64 = 0;
        while (distance <= maxDist and
            isMetaPresent(this.entries[pos].metadata) and
            distanceOfMeta(this.entries[pos].metadata) and
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
                if (!isMetaPresent(pos_meta) || pos_dist == 0) {
                    this.entries[prev_pos].metadata = 0;
                    return deleted;
                }
                this.entries[prev_pos] = this.entries[pos];
                this.entries[prev_pos].metadata = metaOfDistanceAndHash(hashOfMeta(pos_meta), pos_dist);
            }
        }

        return null;
    }
};

test "List" {
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
