const std = @import("std");

fn Entry(comptime K: type, comptime V: type) type {
    return struct {
        key: K,
        value: V,
        pub fn init(k: K, v: V) @This() {
            return .{ .key = k, .value = v };
        }
    };
}

test "map" {}
