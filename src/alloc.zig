const std = @import("std");
const locking = @import("lock.zig");
const state = @import("state.zig");

const NoAlloc = 0xFF_FF_FF_FF_FF_FF_FF_FF;

fn MinInt(comptime Max: u64) type {
    return if (Max < 1 << 8) u8 else if (Max < 1 << 16) u16 else if (Max < 1 << 32) u32 else u64;
}

pub fn BumpAllocator(comptime Entries: u64) type {
    const OffsetTy = MinInt(Entries);
    const Stack = struct { size: u32, stack: [Entries]OffsetTy };
    const GetMachine = state.TrivialDepMachine(*Stack, u64, struct {
        fn drive(s: *Stack) u64 {
            if (s.size <= 0) return NoAlloc;

            s.size -= 1;
            const item = s.stack[s.size];
            return item;
        }
    }.drive);
    const GetMachineCreator = state.TrivialCreator(GetMachine);

    const RetireDepMachine = state.DepMachine(u64, void, *Stack, struct {
        fn drive(offset: u64, s: *Stack) state.Drive(u64, void) {
            s.stack[s.size] = @intCast(offset);
            s.size += 1;
            return state.Drive(u64, void){ .Complete = {} };
        }
    }.drive);
    const RetireMachineCreator = state.TrivialCreator(RetireDepMachine);

    return struct {
        lock: locking.OptLock(Stack),
        pub const RetrieveMachine = locking.OptLock(Stack).WriteStateMachine(GetMachine, u64, GetMachineCreator);
        pub const RetireMachine = locking.OptLock(Stack).WriteStateMachine(RetireDepMachine, void, RetireMachineCreator);
        const This = @This();
        pub fn init() This {
            var a: [Entries]OffsetTy = undefined;
            for (0..Entries) |i| {
                a[i] = @intCast(i);
            }
            return This{ .lock = locking.OptLock(Stack).init(.{ .size = Entries, .stack = a }) };
        }

        pub fn retrieveOffset(this: *This) RetrieveMachine {
            return this.lock.write(GetMachine, u64, GetMachineCreator, GetMachineCreator.init(GetMachine.init({})));
        }

        pub fn retireOffset(this: *This, offset: u64) RetireMachine {
            return this.lock.write(RetireDepMachine, void, RetireMachineCreator, RetireMachineCreator.init(RetireDepMachine.init(offset)));
        }
    };
}

var global_mutex = std.Thread.Mutex{};
var global_mutex2 = std.Thread.Mutex{};

fn RevolverAllocator(comptime Slots: u64, comptime ItemsPerSlot: u64) type {
    const AllocTy = BumpAllocator(ItemsPerSlot);
    return struct {
        const RetrieveMachineState = struct {
            allocators: *[Slots]AllocTy,
            local_allocator: *This.LocalAllocator,
            machine: ?AllocTy.RetrieveMachine,
            freestackcomplete: ?u64,
            index: u64,
            tries: u8,
        };

        pub const RetrieveMachine = state.Machine(RetrieveMachineState, u64, struct {
            const Drive = state.Drive(RetrieveMachineState, u64);
            fn drive(const_s: RetrieveMachineState) Drive {
                var s = const_s;
                if (s.freestackcomplete) |offset| {
                    return Drive{ .Complete = offset };
                }
                if (s.machine) |machine| {
                    var m = machine;
                    if (m.drive()) |offset| {
                        if (offset != NoAlloc) {
                            return Drive{ .Complete = offset + s.index * ItemsPerSlot };
                        }

                        s.tries += 1;
                        if (s.tries == Slots) {
                            return Drive{ .Complete = NoAlloc };
                        }
                        s.local_allocator.index += 1;
                        s.local_allocator.index %= Slots;
                        s.index = s.local_allocator.index;
                        s.machine = s.allocators[s.index].retrieveOffset();
                        return Drive{ .Incomplete = s };
                    }
                    s.machine = m;
                    return Drive{ .Incomplete = s };
                }
                s.index = s.local_allocator.index;
                s.machine = s.allocators[s.index].retrieveOffset();
                return drive(s);
            }
        }.drive);

        const RetireMachineState = struct {
            allocator: *AllocTy,
            index: u64,
            machine: ?AllocTy.RetireMachine,
            freestackcomplete: bool,
            offset: u64,
        };

        pub const RetireMachine = state.Machine(RetireMachineState, void, struct {
            const Drive = state.Drive(RetireMachineState, void);
            fn drive(const_s: RetireMachineState) Drive {
                var s = const_s;
                if (s.freestackcomplete) {
                    return Drive{ .Complete = {} };
                }
                if (s.machine) |machine| {
                    var m = machine;
                    if (m.drive()) |_| {
                        return Drive{ .Complete = {} };
                    }
                    s.machine = m;
                    return Drive{ .Incomplete = s };
                }
                s.machine = s.allocator.retireOffset(s.offset - s.index * ItemsPerSlot);
                return drive(s);
            }
        }.drive);

        allocators: [Slots]AllocTy,
        const This = @This();
        const LocalAllocator = struct {
            const FreeStackSize = 8;
            main: *This,
            index: u64,
            freestack: [FreeStackSize]u64,
            freestacksize: u64,

            pub fn retrieveOffset(this: *@This()) RetrieveMachine {
                var mstate = RetrieveMachineState{
                    .allocators = &this.main.allocators,
                    .local_allocator = this,
                    .freestackcomplete = null,
                    .machine = null,
                    .tries = 0,
                    .index = 0,
                };
                if (this.freestacksize > 0) {
                    this.freestacksize -= 1;
                    mstate.freestackcomplete = this.freestack[this.freestacksize];
                }
                return RetrieveMachine.init(mstate);
            }

            pub fn retireOffset(this: *@This(), offset: u64) RetireMachine {
                const index = offset / ItemsPerSlot;
                var mstate = RetireMachineState{
                    .allocator = &this.main.allocators[index],
                    .index = index,
                    .freestackcomplete = false,
                    .machine = null,
                    .offset = offset,
                };
                if (this.freestacksize < FreeStackSize) {
                    this.freestack[this.freestacksize] = offset;
                    this.freestacksize += 1;
                    mstate.freestackcomplete = true;
                }
                return RetireMachine.init(mstate);
            }

            pub fn deinit(this: *@This()) void {
                for (0..this.freestacksize) |i| {
                    const offset = this.freestack[i];
                    const index = offset / ItemsPerSlot;
                    var machine = this.main.allocators[index].retireOffset(offset - index * ItemsPerSlot);
                    machine.run();
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

pub fn FixedQueue(comptime T: type, comptime Capacity: usize) type {
    const RCapacity = Capacity + 1;
    return struct {
        const Error = error{
            OutOfSpace,
        };

        read: usize,
        write: usize,
        q: [RCapacity]T,
        const This = @This();
        pub fn init() This {
            return This{ .read = 0, .write = 0, .q = undefined };
        }

        pub fn push(this: *This, item: T) This.Error!void {
            if ((this.write + 1) % RCapacity == this.read) {
                return Error.OutOfSpace;
            }
            this.q[this.write] = item;
            this.write += 1;
            this.write %= RCapacity;
        }

        pub fn pop(this: *This) ?T {
            if (this.read == this.write) {
                return null;
            }
            const item = this.q[this.read];
            this.read += 1;
            this.read %= RCapacity;
            return item;
        }
    };
}

test "alloc tree" {
    const Treet = RevolverAllocator(8, 32);
    var tree = Treet.init();
    var now = try std.time.Timer.start();
    const bench = struct {
        fn benchmark(t: *Treet, ok: *std.atomic.Atomic(i32), failed: *std.atomic.Atomic(i32)) void {
            var local_alloc = t.localAllocator();
            defer local_alloc.deinit();
            for (0..100000) |_| {
                var mallocQ = FixedQueue(Treet.RetrieveMachine, 32).init();
                var freeQ = FixedQueue(Treet.RetireMachine, 32).init();
                var a: [32]u64 = undefined;
                var allocs: u32 = 0;
                for (0..32) |_| {
                    mallocQ.push(local_alloc.retrieveOffset()) catch unreachable;
                }

                while (mallocQ.pop()) |machine| {
                    var m = machine;
                    if (m.drive()) |offset| {
                        if (offset == NoAlloc) {
                            _ = failed.fetchAdd(1, std.atomic.Ordering.Monotonic);
                        } else {
                            a[allocs] = offset;
                            allocs += 1;
                            _ = ok.fetchAdd(1, std.atomic.Ordering.Monotonic);
                        }
                    } else {
                        mallocQ.push(m) catch unreachable;
                    }
                }
                for (0..allocs) |i| {
                    freeQ.push(local_alloc.retireOffset(a[i])) catch unreachable;
                }
                while (freeQ.pop()) |machine| {
                    var m = machine;
                    if (m.drive() == null) {
                        freeQ.push(m) catch unreachable;
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
    std.debug.print("Time: {}us = {d:.0} ops / sec\n", .{ now.read() / 1000, (100_000.0 * 6.0 * 32.0) / (@as(f64, @floatFromInt(now.read())) / 1_000_000_000.0) });
    std.debug.print("{} ok and {} failed\n", .{ ok.load(std.atomic.Ordering.Monotonic), failed.load(std.atomic.Ordering.Monotonic) });
}
