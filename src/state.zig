pub fn Drive(comptime State: type, comptime Result: type) type {
    return union(enum) { Incomplete: State, Complete: Result };
}

pub fn Machine(comptime State: type, comptime Result: type) type {
    return struct {
        const This = @This();
        state: State,
        drive: *const fn (State) Drive(State, Result),

        pub fn run(this: *This) Result {
            var t = this;
            while (true) {
                const result = t.drive(t.state);
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

fn dep_driver(comptime State: type, comptime Result: type, comptime Dep: type) *const fn (DepDriverState(State, Result, Dep)) Drive(DepDriverState(State, Result, Dep), Result) {
    return struct {
        const D = Drive(DepDriverState(State, Result, Dep), Result);
        pub fn drive(state: DepDriverState(State, Result, Dep)) D {
            const s = state.f(state.s, state.d);
            return switch (s) {
                Drive(State, Result).Incomplete => |v| D{ .Incomplete = .{ .f = state.f, .d = state.d, .s = v } },
                Drive(State, Result).Complete => |r| D{ .Complete = r },
            };
        }
    }.drive;
}

pub fn DepMachine(comptime State: type, comptime Result: type, comptime Dep: type) type {
    return struct {
        const This = @This();

        state: State,
        drive: *const fn (State, Dep) Drive(State, Result),

        pub fn bind(this: *This, dep: Dep) Machine(DepDriverState(State, Result, Dep), Result) {
            return .{
                .drive = dep_driver(State, Result, Dep),
                .state = .{
                    .f = this.drive,
                    .d = dep,
                    .s = this.state,
                },
            };
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
    var countdown_machine = Machine(i32, i32){
        .state = 10, // Start countdown from 10
        .drive = countdown_drive,
    };
    _ = countdown_machine.run();
}

fn bind_drive(a: i32, b: i32) Drive(i32, i32) {
    const D = Drive(i32, i32);
    if (a == 128) {
        return D{ .Complete = a };
    }
    return D{ .Incomplete = a * b };
}

test "bind machine" {
    const expect = std.testing.expect;
    var bind_machine = DepMachine(i32, i32, i32){
        .state = 2,
        .drive = bind_drive,
    };
    var machine = bind_machine.bind(2);
    try expect(machine.run() == 128);
}
