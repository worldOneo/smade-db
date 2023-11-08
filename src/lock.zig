const std = @import("std");

pub fn OptLock(comptime T: type) type {
    return struct {
        const This = @This();
        const Version = std.atomic.Atomic(u64);
        version: Version,
        value: T,
        pub fn init(value: T) This {
            return This{ .value = value, .version = Version.init(0) };
        }
        pub fn tryLock(this: *This) ?*T {
            const ver = this.version.load(std.atomic.Ordering.Acquire);

            if (ver & 1 == 1) {
                return null;
            }
            if (this.version.tryCompareAndSwap(ver, ver + 1, std.atomic.Ordering.Monotonic, std.atomic.Ordering.Monotonic) != null) {
                return null;
            }
            return &this.value;
        }

        pub fn unlock(this: *This) void {
            const prev = this.version.fetchAdd(1, std.atomic.Ordering.Release);
            if (prev % 2 == 0) unreachable("Unlocked unlocked value");
        }

        pub const Read = struct { version: u64, data: *const T };

        pub fn startRead(this: *This) ?Read {
            const ver = this.version.load(std.atomic.Ordering.Acquire);
            if (ver & 1 == 1) {
                return null;
            }
            return Read{ .version = ver, .data = &this.value };
        }
        pub fn verifyRead(this: *This, old_read: Read) bool {
            const ver = this.version.load(std.atomic.Ordering.Acquire);
            return ver == old_read.version;
        }
    };
}
