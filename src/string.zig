const std = @import("std");
const alloc = @import("./alloc.zig");

pub const String = struct {
    value: [3]usize,
    const SmallString = struct {
        data: [24]u8,
    };
    const LargeString = struct {
        length: u64,
        capacity: u64,
        data: [*]u8,
    };
    const This = @This();

    pub fn fromInt(integer: i64) This {
        var inner = [3]usize{ 0, 0, 0 };
        var sms = @as(*[24]u8, @ptrCast(&inner));
        sms[23] = 1;
        var num = integer;
        var pos: usize = 0;
        if (num < 0) {
            sms[pos] = '-';
            num = -num;
            pos += 1;
        }

        var powers: i64 = 18;
        var written = false;
        while (powers > -1) : (powers -= 1) {
            const power = std.math.pow(i64, 10, powers);
            const digit = @divFloor(num, power);
            if (written or digit > 0) {
                written = true;
                sms[pos] = '0' + @as(u8, @intCast(digit));
                pos += 1;
                num -= digit * power;
            }
        }

        if (!written) {
            sms[pos] = '0';
            pos += 1;
        }
        sms[23] = @intCast((pos << 2) | 1);

        const value = This{ .value = inner };
        return value;
    }

    pub fn empty() This {
        var inner = [3]usize{ 0, 0, 0 };
        var sms = @as(*[24]u8, @ptrCast(&inner));
        sms[23] = 1;
        const value = This{ .value = inner };
        return value;
    }

    fn isSmall(this: *const This) bool {
        var sms: *const SmallString = @ptrCast(this);
        return sms.data[23] & 1 == 1;
    }

    fn smallSize(this: *const This) usize {
        var sms: *const SmallString = @ptrCast(this);
        return @intCast(sms.data[23] >> 2); // 2 is for user map value
    }

    pub fn append(this: *This, data: []const u8, allocator: *alloc.LocalAllocator) ?void {
        if (this.isSmall()) {
            return this.appendSms(data, allocator);
        }
        return this.appendString(data, allocator);
    }

    fn appendSms(this: *This, data: []const u8, allocator: *alloc.LocalAllocator) ?void {
        var sms: *SmallString = @ptrCast(this);
        const length = this.smallSize();
        if (length + data.len > 23) {
            const new = allocator.allocateSlice(u8, length + data.len) orelse return null;
            @memcpy(new[0..length], sms.data[0..length]);
            @memcpy(new[length..(length + data.len)], data);
            const largeString = LargeString{ .length = length + data.len, .capacity = new.len, .data = @ptrCast(new) };
            var thisLarge: *LargeString = @ptrCast(this);
            thisLarge.* = largeString;
            return {};
        }
        @memcpy(sms.data[length..(length + data.len)], data);
        sms.data[23] = (@as(u8, @intCast(length + data.len)) << 2) | 1; // 2 is for user map value
        return {};
    }

    fn appendString(this: *This, data: []const u8, allocator: *alloc.LocalAllocator) ?void {
        var thisLarge: *LargeString = @ptrCast(this);
        const length = thisLarge.length;
        if (length + data.len > thisLarge.capacity) {
            const new = allocator.allocateSlice(u8, length + data.len) orelse return null;
            @memcpy(new[0..length], thisLarge.data[0..length]);
            @memcpy(new[length..(length + data.len)], data);
            allocator.freeSlice(u8, thisLarge.data[0..thisLarge.capacity]);
            thisLarge.* = LargeString{ .length = length + data.len, .capacity = new.len, .data = @ptrCast(new) };
            return {};
        }
        @memcpy(thisLarge.data[length..(length + data.len)], data);
        thisLarge.length = length + data.len;
    }

    pub fn sliceView(this: *const This) []const u8 {
        var thisLarge: *const LargeString = @ptrCast(this);
        var sms: *const SmallString = @ptrCast(this);
        if (this.isSmall()) {
            return sms.data[0..this.smallSize()];
        }
        return thisLarge.data[0..thisLarge.length];
    }

    pub fn len(this: *const This) usize {
        return this.sliceView().len;
    }

    pub fn eql(this: *const This, other: *const String) bool {
        return std.mem.eql(u8, this.sliceView(), other.sliceView());
    }

    pub fn deinit(this: *This, allocator: *alloc.LocalAllocator) void {
        if (!this.isSmall()) {
            var thisLarge: *LargeString = @ptrCast(this);
            allocator.freeSlice(u8, thisLarge.data[0..thisLarge.capacity]);
        }
    }

    pub fn hash(this: *const This) u64 {
        return std.hash_map.hashString(this.sliceView());
    }

    pub fn clone(this: *const This, allocator: *alloc.LocalAllocator) This {
        var new = empty();
        new.append(this.sliceView(), allocator);
        return new;
    }
};

test "string.String" {
    const expect = std.testing.expect;
    var ga = try alloc.GlobalAllocator.init(10, std.heap.page_allocator);
    var la = alloc.LocalAllocator.init(&ga);

    try expect(@sizeOf(String) == @sizeOf(String.SmallString) and @sizeOf(String) == @sizeOf(String.LargeString) and @sizeOf(String) == 24);
    var s1 = String.empty();
    try expect(s1.append("Hello, World!", &la) != null);
    var s2 = String.empty();
    try expect(s2.append("Hello, World!", &la) != null);
    try expect(s1.isSmall());
    try expect(s2.isSmall());
    try expect(s1.eql(&s2));
    try expect(s2.append("01234567890abcdefghjiklmnop", &la) != null);
    try expect(!s1.eql(&s2));
    try expect(!s2.isSmall());
    try expect(std.mem.eql(u8, s2.sliceView(), "Hello, World!01234567890abcdefghjiklmnop"));
    try expect(std.mem.eql(u8, s1.sliceView(), "Hello, World!"));
    s1.deinit(&la);
    s2.deinit(&la);
}

test "string.String.fromInt" {
    const expect = std.testing.expect;
    const s0 = String.fromInt(0);
    const s1 = String.fromInt(1);
    const s_1 = String.fromInt(-1);
    const s1234 = String.fromInt(1234);
    const s_1234 = String.fromInt(-1234);
    const s2345678901 = String.fromInt(2345678901);
    const s_2345678901 = String.fromInt(-2345678901);

    try expect(std.mem.eql(u8, s0.sliceView(), "0"));
    try expect(std.mem.eql(u8, s1.sliceView(), "1"));
    try expect(std.mem.eql(u8, s_1.sliceView(), "-1"));
    try expect(std.mem.eql(u8, s1234.sliceView(), "1234"));
    try expect(std.mem.eql(u8, s_1234.sliceView(), "-1234"));
    try expect(std.mem.eql(u8, s2345678901.sliceView(), "2345678901"));
    try expect(std.mem.eql(u8, s_2345678901.sliceView(), "-2345678901"));
}
