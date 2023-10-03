const std = @import("std");

const NoAlloc = 0xFF_FF_FF_FF_FF_FF_FF_FF;

fn MinInt(comptime Max: u64) type {
    return if (Max < 1 << 8) u8 else if (Max < 1 << 16) u16 else if (Max < 1 << 32) u32 else u64;
}

pub fn BumpAllocator(comptime Entries: u64) type {
    const OffsetTy = MinInt(Entries);

    return struct {
        mutex: std.Thread.Mutex,
        stack_size: u32,
        stack: [Entries]OffsetTy,
        const This = @This();
        pub fn init() This {
            var a: [Entries]OffsetTy = undefined;
            for (0..Entries) |i| {
                a[i] = @intCast(i);
            }
            return This{
                .mutex = std.Thread.Mutex{},
                .stack_size = Entries,
                .stack = a,
            };
        }

        pub fn retrieveOffset(this: *This) u64 {
            this.mutex.lock();
            defer this.mutex.unlock();
            if (this.stack_size <= 0) return NoAlloc;
            const item = this.stack[this.stack_size - 1];
            this.stack_size -= 1;
            return item;
        }

        pub fn retireOffset(this: *This, offset: u64) void {
            this.mutex.lock();
            defer this.mutex.unlock();
            this.stack[this.stack_size] = @intCast(offset);
            this.stack_size += 1;
        }
    };
}

fn RevolverAllocator(comptime Slots: u64, comptime ItemsPerSlot: u64) type {
    return struct {
        const AllocTy = BumpAllocator(ItemsPerSlot);
        allocators: [Slots]AllocTy,
        const This = @This();
        const LocalAllocator = struct {
            const FreeStackSize = 8;
            main: *This,
            index: u64,
            freestack: [FreeStackSize]u64,
            freestacksize: u64,

            pub fn retrieveOffset(this: *@This()) u64 {
                if (this.freestacksize > 0) {
                    this.freestacksize -= 1;
                    return this.freestack[this.freestacksize];
                }
                var item: u64 = NoAlloc;
                for (0..Slots) |_| {
                    this.index += 1;
                    this.index %= Slots;
                    item = this.main.allocators[this.index].retrieveOffset();
                    if (item != NoAlloc) {
                        break;
                    }
                }
                if (item == NoAlloc) {
                    return NoAlloc;
                }
                const itemAdjusted = item + this.index * ItemsPerSlot;
                return itemAdjusted;
            }

            pub fn retireOffset(this: *@This(), offset: u64) void {
                if (this.freestacksize < FreeStackSize) {
                    this.freestack[this.freestacksize] = offset;
                    this.freestacksize += 1;
                    return;
                }
                const index = offset / ItemsPerSlot;
                this.main.allocators[index].retireOffset(offset - index * ItemsPerSlot);
            }

            pub fn deinit(this: *@This()) void {
                for (0..this.freestacksize) |i| {
                    const offset = this.freestack[i];
                    const index = offset / ItemsPerSlot;
                    this.main.allocators[index].retireOffset(offset - index * ItemsPerSlot);
                }
            }
        };
        pub fn init() This {
            var revolver: [Slots]AllocTy = undefined;
            for (0..Slots) |i| {
                revolver[i] = AllocTy.init();
            }
            return This{ .allocators = revolver };
        }
        pub fn localAllocator(this: *This) This.LocalAllocator {
            return This.LocalAllocator{
                .index = 0,
                .main = this,
                .freestack = undefined,
                .freestacksize = 0,
            };
        }
    };
}

test "alloc tree" {
    const Treet = RevolverAllocator(12, 32);
    var tree = Treet.init();

    var now = try std.time.Timer.start();
    const bench = struct {
        fn benchmark(t: *Treet, ok: *std.atomic.Atomic(i32), failed: *std.atomic.Atomic(i32)) void {
            var local_alloc = t.localAllocator();
            defer local_alloc.deinit();
            for (0..100000) |_| {
                var a: [32]u64 = undefined;
                for (0..32) |i| {
                    a[i] = local_alloc.retrieveOffset();
                    if (a[i] == NoAlloc) {
                        _ = failed.fetchAdd(1, std.atomic.Ordering.Monotonic);
                    } else {
                        _ = ok.fetchAdd(1, std.atomic.Ordering.Monotonic);
                    }
                }
                for (0..32) |i| {
                    if (a[i] != NoAlloc) {
                        local_alloc.retireOffset(a[i]);
                    }
                }
            }
        }
    };
    var threads: [6]std.Thread = undefined;
    var ok = std.atomic.Atomic(i32).init(0);
    var failed = std.atomic.Atomic(i32).init(0);
    for (0..6) |i| {
        threads[i] = try std.Thread.spawn(.{}, bench.benchmark, .{ &tree, &ok, &failed });
    }
    for (0..6) |i| {
        threads[i].join();
    }
    std.debug.print("Time: {}us = {d:.0} ops / core / sec\n", .{ now.read() / 1000, (100_000.0 * 32.0) / (@as(f64, @floatFromInt(now.read())) / 1_000_000_000.0) });
    std.debug.print("{} ok and {} failed\n", .{ ok.load(std.atomic.Ordering.Monotonic), failed.load(std.atomic.Ordering.Monotonic) });
}
