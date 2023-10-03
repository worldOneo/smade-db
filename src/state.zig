pub fn Drive(comptime State: type, comptime Result: type) type {
    return union(enum) { Incomplete: State, Complete: Result };
}

pub fn Machine(comptime State: type, comptime Result: type, comptime driver: fn (State) Drive(State, Result)) type {
    return struct {
        const This = @This();
        state: State,

        pub fn init(
            state: State,
        ) This {
            return This{ .state = state };
        }

        pub fn run(this: *This) Result {
            var t = this;
            while (true) {
                const result = driver(t.state);
                switch (result) {
                    Drive(State, Result).Complete => |value| return value,
                    Drive(State, Result).Incomplete => |state| t.state = state,
                }
            }
        }

        pub fn drive(this: *This) ?Result {
            const result = driver(this.state);
            switch (result) {
                Drive(State, Result).Complete => |value| return value,
                Drive(State, Result).Incomplete => |state| this.state = state,
            }
            return {};
        }
    };
}

fn DepDriverState(comptime State: type, comptime Result: type, comptime Dep: type) type {
    return struct { f: *const fn (State, Dep) Drive(State, Result), d: Dep, s: State };
}

pub fn DepMachine(comptime State: type, comptime Result: type, comptime Dep: type, comptime driver: fn (State, Dep) Drive(State, Result)) type {
    return struct {
        const This = @This();

        state: State,

        pub fn init(state: State) This {
            return This{ .state = state };
        }

        fn dep_drive(state: DepDriverState(State, Result, Dep)) Drive(DepDriverState(State, Result, Dep), Result) {
            const D = Drive(DepDriverState(State, Result, Dep), Result);
            const s = state.f(state.s, state.d);
            return switch (s) {
                Drive(State, Result).Incomplete => |v| D{ .Incomplete = .{ .f = state.f, .d = state.d, .s = v } },
                Drive(State, Result).Complete => |r| D{ .Complete = r },
            };
        }
        const BoundMachine = Machine(DepDriverState(State, Result, Dep), Result, This.dep_drive);

        pub fn bind(this: *This, dep: Dep) BoundMachine {
            return BoundMachine.init(.{
                .f = driver,
                .d = dep,
                .s = this.state,
            });
        }

        pub fn run(this: *This, dep: Dep) Result {
            var t = this;
            while (true) {
                const result = this.drive(dep);
                switch (result) {
                    Drive(State, Result).Complete => |value| return value,
                    Drive(State, Result).Incomplete => |state| t.state = state,
                }
            }
        }

        pub fn drive(this: *This, dep: Dep) Drive(State, Result) {
            return driver(this.state, dep);
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

pub fn trivialMachine_fn(comptime Result: type, comptime func: fn () Result) fn (void) Drive(void, Result) {
    return struct {
        pub fn f(state: void) Drive(void, Result) {
            _ = state;
            return Drive(void, Result){ .Complete = func() };
        }
    }.f;
}

pub fn trivialMachine(comptime Result: type, comptime Fn: fn () Result) Machine(void, Result, trivialMachine_fn(Result, Fn)) {
    return Machine(void, Result, trivialMachine_fn(Result, Fn)).init({});
}

pub fn trivialDepMachine_fn(comptime Result: type, comptime Dep: type, comptime func: fn (dep: Dep) Result) fn (void, Dep) Drive(void, Result) {
    return struct {
        pub fn f(state: void, dep: Dep) Drive(void, Result) {
            _ = state;
            return Drive(void, Result){ .Complete = func(dep) };
        }
    }.f;
}

pub fn trivialDepMachine(comptime Dep: type, comptime Result: type, comptime Fn: fn (Dep) Result) DepMachine(void, Result, Dep, trivialDepMachine_fn(Result, Dep, Fn)) {
    return DepMachine(void, Result, Dep, trivialDepMachine_fn(Result, Dep, Fn)).init({});
}

pub fn trivialCreator_fn(comptime Type: type) fn (*Type) Type {
    return struct {
        pub fn f(state: *Type) Type {
            return state.*;
        }
    }.f;
}

pub fn trivialCreator(comptime Type: type, value: Type) Creator(Type, Type, trivialCreator_fn(Type)) {
    return Creator(Type, Type, trivialCreator_fn(Type)).create(value);
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
    var countdown_machine = Machine(i32, i32, countdown_drive).init(10);
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
    var bind_machine = DepMachine(i32, i32, i32, bind_drive).init(2);
    var machine = bind_machine.bind(2);
    try expect(machine.run() == 128);
}

test "creator" {
    var creator = Creator(i32, i32, struct {
        fn drive(state: *i32) i32 {
            state.* += 1;
            return state.*;
        }
    }.drive).create(0);
    try expect(creator.new() == 1);
    try expect(creator.new() == 2);
    try expect(creator.new() == 3);
    try expect(creator.new() == 4);
}

test "trivial machine" {
    var machine = trivialMachine(i32, struct {
        fn drive() i32 {
            return 2;
        }
    }.drive);
    try expect(machine.run() == 2);
}

test "trivial dep machine" {
    var machine = trivialDepMachine(i32, i32, struct {
        fn drive(dep: i32) i32 {
            return dep + 2;
        }
    }.drive);
    try expect(machine.run(2) == 4);
    try expect(machine.run(5) == 7);
}
