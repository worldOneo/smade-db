const std = @import("std");
const state = @import("state.zig");

pub fn LockReadState(comptime T: type, comptime DepMachine: type, comptime Creator: type, comptime Result: type) type {
    return struct {
        const State = union(enum) {
            Read: struct {
                lock: *OptLock(T),
                creator: Creator,
            },
            DriveState: struct { machine: DepMachine, lock: *OptLock(T), creator: Creator, version: u64 },
            Verify: struct { version: u64, lock: *OptLock(T), creator: Creator, result: Result },
        };
        const This = @This();
        const Drive = state.Drive(This.State, Result);
        state: This.State,
        pub fn drive(self: This.State) Drive {
            switch (self) {
                This.State.Read => |v| {
                    const ver = v.lock.version.load(std.atomic.Ordering.Acquire);
                    if (ver & 1 == 1) {
                        return Drive{ .Incomplete = self };
                    }
                    var creator = v.creator;
                    const new = creator.new();
                    return drive(This.State{ .DriveState = .{ .creator = creator, .lock = v.lock, .version = ver, .machine = new } });
                },
                This.State.DriveState => |v| {
                    var machine = v.machine;
                    const dep: *const T = &v.lock.value;
                    const res = machine.drive(dep);
                    switch (res) {
                        @TypeOf(res).Incomplete => |ms| {
                            machine.state = ms;
                            return Drive{ .Incomplete = This.State{ .DriveState = .{ .creator = v.creator, .lock = v.lock, .version = v.version, .machine = machine } } };
                        },
                        @TypeOf(res).Complete => |ms| return drive(This.State{ .Verify = .{ .creator = v.creator, .lock = v.lock, .version = v.version, .result = ms } }),
                    }
                },
                This.State.Verify => |v| {
                    const ver = v.lock.version.load(std.atomic.Ordering.Unordered);
                    if (ver != v.version) {
                        return Drive{ .Incomplete = This.State{ .Read = .{ .creator = v.creator, .lock = v.lock } } };
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
        const Drive = state.Drive(This.State, Result);
        state: This.State,
        pub fn drive(self: This.State) Drive {
            switch (self) {
                This.State.Acquire => |v| {
                    const ver = v.lock.version.load(std.atomic.Ordering.Acquire);

                    if (ver & 1 == 1) {
                        return Drive{ .Incomplete = self };
                    }

                    if (v.lock.version.compareAndSwap(ver, ver + 1, std.atomic.Ordering.Monotonic, std.atomic.Ordering.Monotonic)) |_| {
                        return Drive{ .Incomplete = self };
                    }

                    var creator = v.creator;
                    const new = creator.new();
                    return drive(This.State{ .DriveState = .{ .creator = creator, .lock = v.lock, .machine = new } });
                },
                This.State.DriveState => |v| {
                    var machine = v.machine;
                    const res = machine.drive(&v.lock.value);
                    switch (res) {
                        @TypeOf(res).Incomplete => |ms| {
                            machine.state = ms;
                            return Drive{ .Incomplete = This.State{ .DriveState = .{ .creator = v.creator, .lock = v.lock, .machine = machine } } };
                        },
                        @TypeOf(res).Complete => |ms| return drive(This.State{ .Release = .{ .creator = v.creator, .lock = v.lock, .result = ms } }),
                    }
                },
                This.State.Release => |v| {
                    const ver = v.lock.version.fetchAdd(1, std.atomic.Ordering.Release);
                    std.debug.print("Unlocked to: {}", .{ver});
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

        fn ReadStateMachine(comptime DepMachine: type, comptime Result: type, comptime Creator: type) type {
            const LockRead = LockReadState(T, DepMachine, Creator, Result);
            return state.Machine(LockRead.State, Result, LockRead.drive);
        }

        fn WriteStateMachine(comptime DepMachine: type, comptime Result: type, comptime Creator: type) type {
            const LockWrite = LockWriteState(T, DepMachine, Creator, Result);
            return state.Machine(LockWrite.State, Result, LockWrite.drive);
        }

        pub fn read(this: *This, comptime DepMachine: type, comptime Result: type, comptime Creator: type, creator: Creator) ReadStateMachine(DepMachine, Result, Creator) {
            return ReadStateMachine(DepMachine, Result, Creator).init(LockReadState(T, DepMachine, Creator, Result).createState(creator, this));
        }

        pub fn write(this: *This, comptime DepMachine: type, comptime Result: type, comptime Creator: type, creator: Creator) WriteStateMachine(DepMachine, Result, Creator) {
            return WriteStateMachine(DepMachine, Result, Creator).init(LockWriteState(T, DepMachine, Creator, Result).createState(creator, this));
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
        var extractor = state.trivialDepMachine(*const i32, i32, test_read);
        var creator = state.trivialCreator(@TypeOf(extractor), extractor);
        var machine = lock.read(@TypeOf(extractor), i32, @TypeOf(creator), creator);
        try std.testing.expect(machine.run() == 123);
    }
    {
        var modifier = state.trivialDepMachine(*i32, i32, test_incr);
        var creator = state.trivialCreator(@TypeOf(modifier), modifier);
        var modmachine = lock.write(@TypeOf(modifier), i32, @TypeOf(creator), creator);
        try std.testing.expect(modmachine.run() == 124);
    }
    {
        var extractor = state.trivialDepMachine(*const i32, i32, test_read);
        var creator = state.trivialCreator(@TypeOf(extractor), extractor);
        var machine = lock.read(@TypeOf(extractor), i32, @TypeOf(creator), creator);
        try std.testing.expect(machine.run() == 124);
    }
}
