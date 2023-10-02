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
                    const res = machine.drive(&v.lock.value);
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

        pub fn read(this: *This, comptime DepMachine: type, comptime Result: type, comptime Creator: type, creator: Creator) ReadStateMachine(DepMachine, Result, Creator) {
            return ReadStateMachine(DepMachine, Result, Creator).init(LockReadState(T, DepMachine, Creator, Result).createState(creator, this));
        }
    };
}

fn test_read(s: *i32) i32 {
    return s.*;
}

test "lock" {
    var lock = OptLock(i32).init(123);
    var extractor = state.trivialDepMachine(*i32, i32, test_read);
    var creator = state.trivialCreator(@TypeOf(extractor), extractor);
    var machine = lock.read(@TypeOf(extractor), i32, @TypeOf(creator), creator);
    try std.testing.expect(machine.run() == 123);
}
