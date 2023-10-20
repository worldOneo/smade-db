pub fn Drive(comptime Result: type) type {
    return union(enum) { Incomplete, Complete: Result };
}

pub fn Machine(comptime State: type, comptime Result: type, comptime driver: fn (*State) Drive(Result)) type {
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
                const result = driver(&t.state);
                switch (result) {
                    Drive(Result).Complete => |value| return value,
                    Drive(Result).Incomplete => {},
                }
            }
        }

        pub fn drive(this: *This) ?Result {
            const result = driver(&this.state);
            switch (result) {
                Drive(Result).Complete => |value| return value,
                Drive(Result).Incomplete => return null,
            }
        }
    };
}

fn DepDriverState(comptime State: type, comptime Result: type, comptime Dep: type) type {
    return struct { f: *const fn (*State, Dep) Drive(Result), d: Dep, s: State };
}

pub fn DepMachine(comptime State: type, comptime Result: type, comptime Dep: type, comptime driver: fn (*State, Dep) Drive(Result)) type {
    return struct {
        const This = @This();

        state: State,

        pub fn init(state: State) This {
            return This{ .state = state };
        }

        fn dep_drive(state: *DepDriverState(State, Result, Dep)) Drive(Result) {
            const D = Drive(Result);
            const s = state.f(&state.s, state.d);
            return switch (s) {
                Drive(Result).Incomplete => .Incomplete,
                Drive(Result).Complete => |r| D{ .Complete = r },
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
            while (true) {
                const result = this.drive(dep);
                switch (result) {
                    Drive(Result).Complete => |value| return value,
                    Drive(Result).Incomplete => {},
                }
            }
        }

        pub fn drive(this: *This, dep: Dep) Drive(Result) {
            return driver(&this.state, dep);
        }

        pub fn step_drive(this: *This, dep: Dep) ?Result {
            const result = this.drive(dep);
            return switch (result) {
                Drive(Result).Complete => |value| value,
                Drive(Result).Incomplete => null,
            };
        }
    };
}

pub fn Creator(comptime Result: type, comptime State: type, comptime Fn: fn (*State) Result, comptime deinit: fn (*State, Result) void) type {
    return struct {
        const This = @This();
        const newf = Fn;
        state: State,
        pub fn init(state: State) This {
            return This{
                .state = state,
            };
        }

        pub fn invalidate(this: *This, state: Result) void {
            deinit(&this.state, state);
        }

        pub fn new(this: *This) Result {
            return This.newf(&this.state);
        }
    };
}

pub fn trivialMachine_fn(comptime Result: type, comptime func: fn () Result) fn (*void) Drive(Result) {
    return struct {
        pub fn f(state: *void) Drive(Result) {
            _ = state;
            return Drive(Result){ .Complete = func() };
        }
    }.f;
}

pub fn trivialMachine(comptime Result: type, comptime Fn: fn () Result) Machine(void, Result, trivialMachine_fn(Result, Fn)) {
    return Machine(void, Result, trivialMachine_fn(Result, Fn)).init({});
}

pub fn trivialDepMachine_fn(comptime Result: type, comptime Dep: type, comptime func: fn (dep: Dep) Result) fn (*void, Dep) Drive(Result) {
    return struct {
        pub fn f(state: *void, dep: Dep) Drive(Result) {
            _ = state;
            return Drive(Result){ .Complete = func(dep) };
        }
    }.f;
}

pub fn TrivialDepMachine(comptime Dep: type, comptime Result: type, comptime Fn: fn (Dep) Result) type {
    return DepMachine(void, Result, Dep, trivialDepMachine_fn(Result, Dep, Fn));
}

pub fn trivialDepMachine(comptime Dep: type, comptime Result: type, comptime Fn: fn (Dep) Result) TrivialDepMachine(Dep, Result, Fn) {
    return TrivialDepMachine(Dep, Result, Fn).init({});
}

pub fn trivialCreator_fn(comptime Type: type) fn (*Type) Type {
    return struct {
        pub fn f(state: *Type) Type {
            return state.*;
        }
    }.f;
}

pub fn TrivialCreator(comptime Type: type) type {
    return Creator(Type, Type, trivialCreator_fn(Type), struct {
        fn deinit(_: *Type, _: Type) void {}
    }.deinit);
}

pub fn trivialCreator(comptime Type: type, value: Type) TrivialCreator(Type) {
    return TrivialCreator(Type).init(value);
}

const std = @import("std");
fn countdown_drive(count: *i32) Drive(i32) {
    const D = Drive(i32);
    if (count.* > 0) {
        count.* -= 1;
        return .Incomplete;
    } else {
        return D{ .Complete = 0 };
    }
}

test "countdown machine" {
    var countdown_machine = Machine(i32, i32, countdown_drive).init(10);
    _ = countdown_machine.run();
}

fn bind_drive(a: *i32, b: i32) Drive(i32) {
    const D = Drive(i32);
    if (a.* == 128) {
        return D{ .Complete = a.* };
    }
    a.* *= b;
    return .Incomplete;
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
    }.drive, struct {
        fn deinit(_: *i32, _: i32) void {}
    }.deinit).init(0);
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
