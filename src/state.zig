pub fn Drive(comptime State: type, comptime Result: type) type {
    return union(enum) { Incomplete: State, Complete: Result };
}

pub fn Machine(comptime State: type, comptime Result: type, comptime drive: fn (State) Drive(State, Result)) type {
    return struct {
        const This = @This();
        state: State,

        pub fn create(
            state: State,
        ) This {
            return This{ .state = state };
        }

        pub fn run(this: *This) Result {
            var t = this;
            while (true) {
                const result = drive(t.state);
                switch (result) {
                    Drive(State, Result).Complete => |value| return value,
                    Drive(State, Result).Incomplete => |state| t.state = state,
                }
            }
        }
    };
}

fn DepDriverState(comptime State: type, comptime Result: type, comptime Dep: type) type {
    return struct { f: *const fn (State, Dep) Drive(State, Result), d: Dep, s: State };
}

pub fn DepMachine(comptime State: type, comptime Result: type, comptime Dep: type, comptime drive: fn (State, Dep) Drive(State, Result)) type {
    return struct {
        const This = @This();

        state: State,

        pub fn create(state: State) This {
            return This{ .state = state };
        }

        fn dep_driver(state: DepDriverState(State, Result, Dep)) Drive(DepDriverState(State, Result, Dep), Result) {
            const D = Drive(DepDriverState(State, Result, Dep), Result);
            const s = state.f(state.s, state.d);
            return switch (s) {
                Drive(State, Result).Incomplete => |v| D{ .Incomplete = .{ .f = state.f, .d = state.d, .s = v } },
                Drive(State, Result).Complete => |r| D{ .Complete = r },
            };
        }
        const BoundMachine = Machine(DepDriverState(State, Result, Dep), Result, This.dep_driver);

        pub fn bind(this: *This, dep: Dep) BoundMachine {
            return BoundMachine.create(.{
                .f = drive,
                .d = dep,
                .s = this.state,
            });
        }
    };
}

pub fn Creator(comptime Result: type, comptime State: type, comptime Fn: fn (*State) Result) type {
    return struct {
        const This = @This();
        const newf = Fn;
        state: State,
        pub fn create(state: State) This {
            return This{
                .state = state,
            };
        }

        pub fn new(this: *This) Result {
            return This.newf(&this.state);
        }
    };
}

const std = @import("std");
fn countdown_drive(count: i32) Drive(i32, i32) {
    const D = Drive(i32, i32);
    if (count > 0) {
        return D{ .Incomplete = count - 1 };
    } else {
        return D{ .Complete = 0 };
    }
}

test "countdown machine" {
    var countdown_machine = Machine(i32, i32, countdown_drive).create(10);
    _ = countdown_machine.run();
}

fn bind_drive(a: i32, b: i32) Drive(i32, i32) {
    const D = Drive(i32, i32);
    if (a == 128) {
        return D{ .Complete = a };
    }
    return D{ .Incomplete = a * b };
}

const expect = std.testing.expect;
test "bind machine" {
    var bind_machine = DepMachine(i32, i32, i32, bind_drive).create(2);
    var machine = bind_machine.bind(2);
    try expect(machine.run() == 128);
}

const test_creator_t = Creator(i32, i32);
fn test_integer_creator(state: *i32) i32 {
    state.* += 1;
    return state.*;
}

test "creator" {
    var creator = Creator(i32, i32, test_integer_creator).create(0);
    try expect(creator.new() == 1);
    try expect(creator.new() == 2);
    try expect(creator.new() == 3);
    try expect(creator.new() == 4);
}
