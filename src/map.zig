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

    pub fn clear(this: *This, level: u8) void {
        this.metadata = [_]u8{0} ** smallMapEntries;
        this.level = level;
    }

    const SplitEntry = struct {
        k: string.String,
        v: ?Value,
    };

    const Result = union(enum) {
        Present: *Value,
        Absent: *Value,
        Split: SplitEntry,
    };

    pub fn getOrCreate(this: *This, hash: u64, key: string.String) ?Result {
        const shifted_hash = hash >> this.level;
        const starting_pos = shifted_hash % smallMapEntries;
        var pos = starting_pos;
        var distance: u64 = 0;
        while (isMetaPresent(this.entries[pos].metadata) and distanceOfMeta(this.entries[pos].metadata) >= distance and distance <= maxDist) {
            if (hashOfMeta(this.entries[pos].metadata) == shifted_hash and this.entries[pos].key.eql(key)) {
                return Result{ .Present = &this.entries[pos].value };
            }
            pos += 1;
            pos %= smallMapEntries;
            distance += 1;
        }

        if (distance > maxDist) {
            return Result{ .Split = .{ .k = key } };
        }

        if (!isMetaPresent(this.entries[pos].metadata)) {
            this.entries[pos].metadata = metaOfDistanceAndHash(shifted_hash, distance);
            this.entries[pos].key = key;
            return Result{ .Absent = &this.entries[pos].value };
        }

        // TODO: Shift entries
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
