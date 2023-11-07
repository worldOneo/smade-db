const std = @import("std");
const state = @import("state.zig");

pub fn OptLock(comptime T: type) type {
    return struct {
        const This = @This();
        const Version = std.atomic.Atomic(u64);
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
            const ver = this.version.fetchAdd(queueOne, std.atomic.Ordering.Monotonic);
            const splitver = split(ver);
            if (splitver.queue == 0) {
                if (splitver.version > 1_000_000_000) {
                    _ = this.version.fetchSub(999_999_999, std.atomic.Ordering.Acquire);
                } else {
                    _ = this.version.fetchAdd(1, std.atomic.Ordering.Acquire);
                }
                return null;
            }
            var slot = @as(u64, splitver.version & versionBits) + (@as(u64, splitver.queue) << 1);
            while (slot > 1_000_000_000) slot -= 1_000_000_000;
            if (slot < splitver.version) unreachable;
            return @intCast(slot);
        }

        pub fn unlock(this: *This) void {
            const prev = this.version.fetchAdd(dequeUnlock, std.atomic.Ordering.Release);
            // const prevsplit = split(prev);
            // const now = @addWithOverflow(prev, dequeUnlock);
            // const nowsplit = split(now[0]);
            // std.debug.print("Unlocked: {}, {} to {}, {}\n", .{ prevsplit.queue, prevsplit.version, nowsplit.queue, nowsplit.version });
            if (prev % 2 == 0) unreachable("Unlocked unlocked value");
        }

        pub fn tryDeque(this: *This, queue_entry: u32) bool {
            const ver = this.version.load(std.atomic.Ordering.Monotonic);
            const splitver = split(ver);
            if (splitver.version == queue_entry) {
                // const now = @addWithOverflow(ver, 1);
                // const nowsplit = split(now[0]);
                // std.debug.print("Locked {*}: {} : {}, {} to {}, {}\n", .{ this, queue_entry, splitver.queue, splitver.version, nowsplit.queue, nowsplit.version });
                _ = this.version.fetchAdd(1, std.atomic.Ordering.Acquire);
                return true;
            }
            return false;
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

pub fn SimpleLock(comptime T: type) type {
    return struct {
        const This = @This();
        const Version = u32;
        version: Version = 0,
        value: T,

        pub fn init(value: T) This {
            return This{
                .value = value,
            };
        }

        pub fn tryLock(this: *This) ?*T {
            const old = @atomicRmw(u32, &this.version, .Or, 1, std.atomic.Ordering.Acquire);
            if (old & 1 == 0) return &this.value;
            return null;
        }

        pub fn unlock(this: *This) void {
            const old = @atomicRmw(u32, &this.version, .And, 0, std.atomic.Ordering.Release);
            if (old & 1 == 0) unreachable("Unlocked unlocked lock");
        }
    };
}

test "lock.OptLock" {
    const expect = std.testing.expect;
    var lock = OptLock(i32).init(123);
    try expect(lock.queue() == null);
    const q = lock.queue();
    try expect(q != null);
    try expect(!lock.tryDeque(q.?));
    lock.unlock();
    try expect(lock.tryDeque(q.?));
}
