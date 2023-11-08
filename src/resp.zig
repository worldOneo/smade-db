const std = @import("std");
const string = @import("string.zig");
const alloc = @import("alloc.zig");

pub const RespList = struct {
    length: usize,
    data: []RespValue,

    const This = @This();
    pub fn init(length: usize, la: *alloc.LocalAllocator) ?This {
        var data = la.allocateSlice(RespValue, length) orelse return null;
        for (0..length) |i| {
            data[i] = RespValue.from({});
        }
        return This{
            .length = length,
            .data = data,
        };
    }

    pub fn get(this: *This, index: usize) *RespValue {
        if (index >= this.length) {
            unreachable("Index is larger than list.");
        }
        return &this.data[index];
    }

    pub fn deinit(this: *This, la: *alloc.LocalAllocator) void {
        for (0..this.length) |i| {
            this.data[i].deinit(la);
        }
        la.freeSlice(RespValue, this.data);
    }
};

const RespMap = struct {
    const Entry = struct {
        key: ?string.String,
        value: RespValue,
    };

    length: usize,
    data: []Entry,

    const This = @This();
    pub fn init(length: usize, la: *alloc.LocalAllocator) ?This {
        const data = la.allocateSlice(Entry, length) orelse return null;
        return This{
            .length = length,
            .data = data,
        };
    }

    // if not null key is owned by caller, otherwise consumed
    pub fn put(this: *This, key: string.String, value: RespValue) ?RespValue {
        for (0..this.length) |i| {
            if (this.data[i].key) |present_key| {
                if (present_key.eql(&key)) {
                    const val = this.data[i].value;
                    this.data[i].value = value;
                    return val;
                }
            }
        }

        for (0..this.length) |i| {
            if (this.data[i].key == null) {
                this.data[i] = Entry{ .key = key, .value = value };
                return null;
            }
        }
        unreachable;
    }

    pub fn get(this: *const This, key: *const string.String) ?*const RespValue {
        for (0..this.length) |i| {
            if (this.data[i].key) |present_key| {
                if (present_key.eql(key)) {
                    return &this.data[i].value;
                }
            }
        }
        return null;
    }

    pub fn deinit(this: *This, la: *alloc.LocalAllocator) void {
        for (0..this.length) |i| {
            if (this.data[i].key) |str| {
                var v_str = str;
                v_str.deinit(la);
            }
            this.data[i].value.deinit(la);
        }
        la.freeSlice(Entry, this.data);
    }
};

const RespInt = struct {
    value: i64,
    _a: [2]u64 = [2]u64{ 0, 0 },

    pub fn from(value: i64) RespInt {
        return .{ .value = value };
    }
};

pub const RespValue = struct {
    const Flag = enum(usize) {
        Int,
        String,
        List,
        Map,
        Null,
    };

    data: [24]u8,
    flag: Flag,
    // still better than an union
    _pad: [2]usize = [2]usize{ 0, 0 },

    const This = @This();
    pub fn typeFlag(this: *This) Flag {
        return this.flag;
    }

    pub fn isPresent(this: *This) bool {
        return this.flag != .Null;
    }

    pub fn asString(this: *This) ?*string.String {
        if (this.flag == .String) {
            return @ptrCast(@alignCast(&this.data));
        }
        return null;
    }

    pub fn asList(this: *This) ?*RespList {
        if (this.flag == .List) {
            return @ptrCast(@alignCast(&this.data));
        }
        return null;
    }

    pub fn asMap(this: *This) ?*RespMap {
        if (this.flag == .Map) {
            return @ptrCast(@alignCast(&this.data));
        }
        return null;
    }

    pub fn asInt(this: *This) ?i64 {
        if (this.flag == .Int) {
            return @as(*align(1) RespInt, @ptrCast(@alignCast(&this.data))).value;
        }
        return null;
    }

    pub fn from(value: anytype) This {
        if (@TypeOf(value) == void) {
            return .{ .flag = .Null, .data = [_]u8{0} ** 24 };
        }
        var inner: [24]u8 = @as(*const [24]u8, @ptrCast(&value)).*;
        switch (@TypeOf(value)) {
            RespList => return .{ .flag = .List, .data = inner },
            RespMap => return .{ .flag = .Map, .data = inner },
            RespInt => return .{ .flag = .Int, .data = inner },
            string.String => return .{ .flag = .String, .data = inner },
            else => @compileError("Type " ++ @typeName(@TypeOf(value)) ++ " cannot be converted to RespValue"),
        }
    }

    pub fn deinit(this: *This, la: *alloc.LocalAllocator) void {
        switch (this.flag) {
            .String => this.asString().?.deinit(la),
            .List => this.asList().?.deinit(la),
            .Map => this.asMap().?.deinit(la),
            else => {},
        }
    }
};

pub const ParseResult = struct {
    value: RespValue,
    read_until: usize,
};

fn parseInt(resp: []const u8, offset: *usize) !?i64 {
    var int: i64 = 0;
    var mod: i64 = 1;
    var pos = offset.*;
    const frame = resp;
    if (frame[pos] == '-') {
        mod = -1;
        pos += 1;
    }
    while (pos < frame.len and frame[pos] != '\r') {
        if (frame[pos] < '0' or frame[pos] > '9') {
            break;
        }

        var ov = @mulWithOverflow(int, 10);
        if (ov[1] != 0) return error.OverFlow;
        ov = @addWithOverflow(ov[0], frame[pos] - '0');
        if (ov[1] != 0) return error.OverFlow;
        int = ov[0];
        pos += 1;
    }
    if (pos >= frame.len) {
        return null;
    }
    if (frame[pos] != '\r') {
        return error.InvalidInteger;
    }
    pos += 1;
    offset.* = pos;
    return int * mod;
}

pub fn parseResp(resp: []const u8, offset: usize, la: *alloc.LocalAllocator) !?ParseResult {
    if (offset >= resp.len) return null;
    const frame = resp;
    if (frame.len < 3) return null; // _\r\n is I believe the shortest there is.
    var pos = offset;
    const value = switch (frame[pos]) {
        ':' => blk: {
            pos += 1;
            break :blk RespValue.from(RespInt.from(try parseInt(resp, &pos) orelse return null));
        },
        '$' => blk: {
            pos += 1;
            const length = try parseInt(resp, &pos) orelse return null;
            if (pos >= frame.len) {
                return null;
            }
            if (frame[pos] != '\n') {
                return error.MissingTerminator;
            }
            pos += 1;
            const ulength: usize = @intCast(length);
            if (pos + ulength >= frame.len) {
                return null;
            }
            var str = string.String.empty();
            if (str.append(frame[pos .. pos + ulength], la) == null) {
                return error.OutOfMemory;
            }
            pos += ulength;
            if (pos >= frame.len) {
                return null;
            }
            if (frame[pos] != '\r') {
                return error.MissingTerminator;
            }
            pos += 1;
            break :blk RespValue.from(str);
        },
        '+' => blk: {
            pos += 1;
            const start = pos;
            while (pos < frame.len and frame[pos] != '\r') {
                pos += 1;
            }
            if (pos >= frame.len) {
                return null;
            }
            const end = pos;
            var str = string.String.empty();
            if (str.append(frame[start..end], la) == null) {
                return error.OutOfMemory;
            }
            pos += 1;
            break :blk RespValue.from(str);
        },
        '*' => {
            pos += 1;
            const length = try parseInt(resp, &pos) orelse return null;
            if (pos >= frame.len) {
                return null;
            }
            if (frame[pos] != '\n') {
                return error.MissingTerminator;
            }
            pos += 1;
            const ulength: usize = @intCast(length);
            var list = RespList.init(ulength, la) orelse return error.OutOfMemory;
            for (0..ulength) |i| {
                var parsed = try parseResp(resp, pos, la) orelse {
                    list.deinit(la);
                    return null;
                };
                list.get(i).* = parsed.value;
                pos = parsed.read_until + 1;
            }
            return ParseResult{ .value = RespValue.from(list), .read_until = pos };
        },
        '%' => {
            pos += 1;
            const length = try parseInt(resp, &pos) orelse return null;
            if (pos >= frame.len) {
                return null;
            }
            if (frame[pos] != '\n') {
                return error.MissingTerminator;
            }
            const ulength: usize = @intCast(length);
            var map = RespMap.init(ulength, la) orelse return error.OutOfMemory;
            pos += 1;
            for (0..ulength) |_| {
                var key = try parseResp(resp, pos, la) orelse {
                    map.deinit(la);
                    return null;
                };
                pos = key.read_until + 1;

                if (key.value.asString()) |str_key| {
                    var value = try parseResp(resp, pos, la) orelse {
                        map.deinit(la);
                        return null;
                    };
                    pos = key.read_until + 1;
                    if (map.put(str_key.*, value.value)) |v| {
                        var val = v;
                        val.deinit(la);
                        key.value.deinit(la);
                    }
                } else {
                    map.deinit(la);
                    return error.InvalidMapKey;
                }
            }
            return ParseResult{ .value = RespValue.from(map), .read_until = pos };
        },
        else => return error.UnsupportedType,
    };
    if (pos >= frame.len) {
        return null;
    }
    if (frame[pos] != '\n') {
        std.debug.print("pos = {}\n", .{pos});
        return error.MissingTerminator;
    }
    return ParseResult{ .value = value, .read_until = pos };
}

test "resp.Parser" {
    const expect = std.testing.expect;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ga = try alloc.GlobalAllocator.init(50, arena.allocator());
    var la = alloc.LocalAllocator.init(&ga);

    var parsed = (try parseResp(":1234\r\n", 0, &la)).?;
    try expect(parsed.value.asInt() == 1234);

    parsed = (try parseResp("+1234\r\n", 0, &la)).?;
    const _1234 = parsed.value.asString().?.*;
    try expect(std.mem.eql(u8, parsed.value.asString().?.sliceView(), "1234"));

    parsed = (try parseResp("$4\r\n5678\r\n", 0, &la)).?;
    const _5678 = parsed.value.asString().?.*;
    try expect(std.mem.eql(u8, parsed.value.asString().?.sliceView(), "5678"));

    parsed = (try parseResp("*3\r\n+1234\r\n$4\r\n5678\r\n:91011\r\n", 0, &la)).?;
    var list = parsed.value.asList().?;
    try expect(list.get(0).asString().?.eql(&_1234));
    try expect(list.get(1).asString().?.eql(&_5678));
    try expect(list.get(2).asInt() == 91011);

    parsed = (try parseResp("*1\r\n*1\r\n*2\r\n+5678\r\n:91011\r\n", 0, &la)).?;
    list = parsed.value.asList().?;
    var list2 = list.get(0).asList().?;
    var list3 = list2.get(0).asList().?;
    try expect(list3.get(0).asString().?.eql(&_5678));
    try expect(list3.get(1).asInt() == 91011);
    arena.deinit();
}
