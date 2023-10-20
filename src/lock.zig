const std = @import("std");
const state = @import("state.zig");

pub fn LockReadState(comptime T: type, comptime DepMachine: type, comptime Creator: type, comptime Result: type) type {
    return struct {
        const State = union(enum) {
            Read: struct {
                lock: *OptLock(T),
                creator: Creator,
            },
            DriveState: struct { machine: DepMachine, lock: *OptLock(T), creator: Creator, read: OptLock(T).Read },
            Verify: struct {
                machine: DepMachine,
                lock: *OptLock(T),
                creator: Creator,
                read: OptLock(T).Read,
                result: Result,
            },
        };
        const This = @This();
        const Drive = state.Drive(Result);
        state: This.State,
        pub fn drive(self: *This.State) Drive {
            switch (self.*) {
                .Read => |*v| {
                    if (v.lock.startRead()) |read| {
                        var creator = v.creator;
                        const new = creator.new();
                        self.* = This.State{ .DriveState = .{
                            .creator = creator,
                            .lock = v.lock,
                            .read = read,
                            .machine = new,
                        } };
                        return drive(self);
                    }
                    return .Incomplete;
                },
                .DriveState => |*v| {
                    const dep: *const T = &v.lock.value;
                    const res = v.machine.drive(dep);
                    switch (res) {
                        @TypeOf(res).Incomplete => return .Incomplete,
                        @TypeOf(res).Complete => |ms| {
                            self.* = This.State{ .Verify = .{
                                .creator = v.creator,
                                .lock = v.lock,
                                .read = v.read,
                                .result = ms,
                                .machine = v.machine,
                            } };
                            return drive(self);
                        },
                    }
                },
                .Verify => |*v| {
                    if (!v.lock.verifyRead(v.read)) {
                        var creator = &v.creator;
                        creator.invalidate(v.machine);
                        self.* = This.State{ .Read = .{ .creator = v.creator, .lock = v.lock } };
                        return .Incomplete;
                    } else {
                        return Drive{ .Complete = v.result };
                    }
                },
            }
        }

        pub fn createState(creator: Creator, lock: *OptLock(T)) This.State {
            return This.State{ .Read = .{ .lock = lock, .creator = creator } };
        }
    };
}

pub fn LockWriteState(comptime T: type, comptime DepMachine: type, comptime Creator: type, comptime Result: type) type {
    return struct {
        const State = union(enum) {
            Acquire: struct {
                lock: *OptLock(T),
                creator: Creator,
            },
            DriveState: struct { machine: DepMachine, lock: *OptLock(T), creator: Creator },
            Release: struct { lock: *OptLock(T), creator: Creator, result: Result },
        };
        const This = @This();
        const Drive = state.Drive(Result);
        state: This.State,
        pub fn drive(self: *This.State) Drive {
            switch (self.*) {
                .Acquire => |*v| {
                    if (v.lock.tryLock()) |_| {
                        return .Incomplete;
                    }

                    const new = v.creator.new();
                    self.* = This.State{ .DriveState = .{ .creator = v.creator, .lock = v.lock, .machine = new } };
                    return drive(self);
                },
                .DriveState => |*v| {
                    var machine = &v.machine;
                    const res = machine.drive(&v.lock.value);
                    switch (res) {
                        @TypeOf(res).Incomplete => return .Incomplete,
                        @TypeOf(res).Complete => |ms| {
                            v.creator.invalidate(v.machine);
                            self.* = This.State{ .Release = .{ .creator = v.creator, .lock = v.lock, .result = ms } };
                            return drive(self);
                        },
                    }
                },
                .Release => |*v| {
                    v.lock.unlock();
                    return Drive{ .Complete = v.result };
                },
            }
        }

        pub fn createState(creator: Creator, lock: *OptLock(T)) This.State {
            return This.State{ .Acquire = .{ .lock = lock, .creator = creator } };
        }
    };
}

pub fn OptLock(comptime T: type) type {
    return struct {
        const This = @This();
        const Version = std.atomic.Atomic(u64);
        version: Version,
        value: T,

        pub fn init(value: T) This {
            return This{ .value = value, .version = Version.init(0) };
        }

        pub fn ReadStateMachine(comptime DepMachine: type, comptime Result: type, comptime Creator: type) type {
            const LockRead = LockReadState(T, DepMachine, Creator, Result);
            return state.Machine(LockRead.State, Result, LockRead.drive);
        }

        pub fn WriteStateMachine(comptime DepMachine: type, comptime Result: type, comptime Creator: type) type {
            const LockWrite = LockWriteState(T, DepMachine, Creator, Result);
            return state.Machine(LockWrite.State, Result, LockWrite.drive);
        }

        pub fn read(this: *This, comptime DepMachine: type, comptime Result: type, comptime Creator: type, creator: Creator) ReadStateMachine(DepMachine, Result, Creator) {
            return ReadStateMachine(DepMachine, Result, Creator)
                .init(LockReadState(T, DepMachine, Creator, Result)
                .createState(creator, this));
        }

        pub fn write(this: *This, comptime DepMachine: type, comptime Result: type, comptime Creator: type, creator: Creator) WriteStateMachine(DepMachine, Result, Creator) {
            return WriteStateMachine(DepMachine, Result, Creator)
                .init(LockWriteState(T, DepMachine, Creator, Result)
                .createState(creator, this));
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
            _ = this.version.fetchAdd(1, std.atomic.Ordering.Release);
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

fn test_read(s: *const i32) i32 {
    return s.*;
}

fn test_incr(v: *i32) i32 {
    v.* += 1;
    return v.*;
}

test "lock" {
    var lock = OptLock(i32).init(123);
    {
        const extractor = state.TrivialDepMachine(*const i32, i32, test_read);
        const creator = state.TrivialCreator(extractor);
        var machine = lock.read(extractor, i32, creator, creator.init(extractor.init({})));
        try std.testing.expect(machine.run() == 123);
    }
    {
        const modifier = state.TrivialDepMachine(*i32, i32, test_incr);
        const creator = state.TrivialCreator(modifier);
        var modmachine = lock.write(modifier, i32, creator, creator.init(modifier.init({})));
        try std.testing.expect(modmachine.run() == 124);
    }
    {
        const extractor = state.TrivialDepMachine(*const i32, i32, test_read);
        const creator = state.TrivialCreator(extractor);
        var machine = lock.read(extractor, i32, creator, creator.init(extractor.init({})));
        try std.testing.expect(machine.run() == 124);
    }
}
