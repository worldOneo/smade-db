// const std = @import("std");
// const state = @import("state.zig");

// fn OptLock(comptime T: type) type {
//     return struct {
//         const This = @This();
//         const Version = std.atomic.Atomic(u64);
//         version: Version,
//         value: T,

//         pub fn create(value: T) This {
//             return This{ .value = value, .version = Version.init(0) };
//         }

//         pub fn read(comptime DepMachine: type, comptime Result: type, this: *This, machine: Machine) Result {

//         }
//     };
// }
