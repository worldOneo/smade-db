const std = @import("std");

pub fn QueueLock(comptime T: type) type {
    return struct {
        const This = @This();
        const Version = std.atomic.Value(u64);
        version: Version,
        value: T,
        pub fn init(value: T) This {
            return This{ .value = value, .version = Version.init(0) };
        }

        const SplitVer = struct {
            queue: u32,
            version: u32,
        };

        const lower31bits = ((1 << 31) - 1);
        const lower32bits = ((1 << 32) - 1);
        const versionBits = (lower31bits << 1);
        const dequeUnlock = (lower32bits << 32) + 1;
        const queueOne = 1 << 32;

        const queueBits = (~(1 << 63)) & (versionBits << 32);

        fn split(version: u64) SplitVer {
            return .{
                .queue = @intCast(version >> 32),
                .version = @intCast(version & lower32bits),
            };
        }

        pub fn queue(this: *This) ?u32 {
            const ver = this.version.fetchAdd(queueOne, .monotonic);
            const splitver = split(ver);
            if (splitver.queue == 0) {
                if (splitver.version > 1_000_000_000) {
                    _ = this.version.fetchSub(999_999_999, .acquire);
                } else {
                    _ = this.version.fetchAdd(1, .acquire);
                }
                return null;
            }
            var slot = @as(u64, splitver.version & versionBits) + (@as(u64, splitver.queue) << 1);
            while (slot > 1_000_000_000) slot -= 1_000_000_000;
            if (slot < splitver.version) unreachable;
            return @intCast(slot);
        }

        pub fn unlock(this: *This) void {
            const prev = this.version.fetchAdd(dequeUnlock, .release);
            if (prev % 2 == 0) unreachable("Unlocked unlocked value");
        }

        pub fn tryDeque(this: *This, queue_entry: u32) bool {
            const ver = this.version.load(.monotonic);
            const splitver = split(ver);
            if (splitver.version == queue_entry) {
                _ = this.version.fetchAdd(1, .acquire);
                return true;
            }
            return false;
        }

        pub const Read = struct { version: u64, data: *const T };

        pub fn startRead(this: *This) ?Read {
            const ver = this.version.load(.acquire);
            if (ver & 1 == 1) {
                return null;
            }
            return Read{ .version = ver, .data = &this.value };
        }
        pub fn verifyRead(this: *This, old_read: Read) bool {
            const ver = this.version.load(.acquire);
            return ver & versionBits == old_read.version & versionBits;
        }
    };
}

pub fn OptLock(comptime T: type) type {
    return struct {
        const This = @This();
        const Version = std.atomic.Value(u64);
        version: Version,
        value: T,
        pub fn init(value: T) This {
            return This{ .value = value, .version = Version.init(0) };
        }
        pub fn tryLock(this: *This) ?*T {
            const ver = this.version.load(.acquire);

            if (ver & 1 == 1) {
                return null;
            }
            if (this.version.cmpxchgWeak(ver, ver + 1, .monotonic, .monotonic) != null) {
                return null;
            }
            return &this.value;
        }

        pub fn unlock(this: *This) void {
            const prev = this.version.fetchAdd(1, .release);
            if (prev % 2 == 0) unreachable("Unlocked unlocked value");
        }

        pub const Read = struct { version: u64, data: *const T };

        pub fn startRead(this: *This) ?Read {
            const ver = this.version.load(.acquire);
            if (ver & 1 == 1) {
                return null;
            }
            return Read{ .version = ver, .data = &this.value };
        }
        pub fn verifyRead(this: *This, old_read: Read) bool {
            const ver = this.version.load(.acquire);
            return ver == old_read.version;
        }
    };
}
