const resp = @import("resp.zig");
const string = @import("string.zig");
const lock = @import("lock.zig");
const map = @import("map.zig");
const state = @import("state.zig");
const alloc = @import("alloc.zig");
const std = @import("std");

const GetState = struct {
    key: string.String,
    hash: u64,
    allocator: *alloc.LocalAllocator,
    read: ?string.String = null,
};

const GetError = CommandError;
const GetResult = GetError!?string.String;

const GetCreator = state.Creator(GetMachine, GetMachine, struct {
    fn new(s: *GetMachine) GetMachine {
        return s.*;
    }
}.new, struct {
    fn deinit(s: *GetMachine, c_v: GetMachine) void {
        var v = c_v;
        if (v.state.read) |*str| {
            str.deinit(s.state.allocator);
        }
    }
}.deinit);

const GetMachine = state.DepMachine(GetState, GetResult, *const map.SmallMap, struct {
    const Drive = state.Drive(GetResult);
    pub fn drive(s: *GetState, dep: *const map.SmallMap) Drive {
        var maybe_val = dep.get(s.hash, &s.key);
        if (maybe_val) |val| {
            if (val.asConstString()) |str| {
                const clone = str.clone(s.allocator) orelse return Drive{ .Complete = error.OutOfMemory };
                s.read = clone;
                return Drive{ .Complete = clone };
            }
            return Drive{ .Complete = error.TypeNotTrivialReadable };
        }
        return Drive{ .Complete = null };
    }

    pub fn deinit(s: *GetState) void {
        s.key.deinit(s.allocator);
    }
});

const ExGetMachine = map.ExtendibleMap.ReadMachine(GetMachine, GetCreator, GetResult);

const SetState = struct {
    value: map.Value,
    ins_spl_machine: map.InsertAndSplitMachine,
};

const SetError = CommandError;
const SetResult = SetError!map.Value;

const SetMachine = state.Machine(SetState, SetResult, struct {
    const Drive = state.Drive(SetResult);
    pub fn drive(s: *SetState) Drive {
        if (s.ins_spl_machine.drive()) |maybe_value| {
            if (maybe_value) |c_value| {
                var value: map.InsertAndSplitResult = c_value;
                var old = value.value.*;
                value.value.* = s.value;
                value.acquired.lock.unlock();
                if (!c_value.present) {
                    return Drive{ .Complete = map.Value.nil() };
                }
                return Drive{ .Complete = old };
            } else {
                return Drive{ .Complete = error.OutOfMemory };
            }
        }
        return .Incomplete;
    }
});

pub const CommandError = error{
    UnsupportedCommand,
    InvalidArgumentCount,
    InvalidCommandFormat,
    InvalidArguments,
    TypeNotTrivialReadable,
    OutOfMemory,
};

pub const CommandState = union(enum) {
    Set: SetMachine,
    Get: ExGetMachine,

    pub fn init(data: *map.ExtendibleMap, command: *resp.RespList, la: *alloc.LocalAllocator) CommandError!CommandState {
        if (command.length < 2) {
            return error.InvalidArgumentCount;
        }
        if (command.get(0).asString()) |cmd_str| {
            const slice_view = cmd_str.sliceView();
            if (std.mem.eql(u8, slice_view, "GET")) {
                // GET
                if (command.length != 2) return error.InvalidArgumentCount;
                var key: string.String = string.String.empty();

                if (command.get(1).asString()) |arg_str| key = arg_str.* else return error.InvalidArguments;
                command.get(1).* = resp.RespValue.from({});
                const hash = key.hash();
                return CommandState{
                    .Get = data.read(
                        hash,
                        GetMachine,
                        GetCreator,
                        GetResult,
                        GetCreator.init(GetMachine.init(GetState{
                            .allocator = la,
                            .hash = hash,
                            .key = key,
                        })),
                    ),
                };
            } else if (std.mem.eql(u8, slice_view, "SET")) {
                if (command.length != 3) return error.InvalidArgumentCount;
                var key: string.String = string.String.empty();
                var value: string.String = string.String.empty();
                if (command.get(1).asString()) |key_str| key = key_str.* else return error.InvalidArguments;
                if (command.get(2).asString()) |val_str| value = val_str.* else return error.InvalidArguments;
                command.get(1).* = resp.RespValue.from({});
                command.get(2).* = resp.RespValue.from({});

                const insState = map.InsertAndSplitState.init(
                    key,
                    data,
                    la,
                );
                return CommandState{
                    .Set = SetMachine.init(SetState{
                        .value = map.Value.fromString(value),
                        .ins_spl_machine = map.InsertAndSplitMachine.init(insState),
                    }),
                };
            }
            return error.UnsupportedCommand;
        }
        return error.InvalidArgumentCount;
    }
};

pub const CommandResult = CommandError!map.Value;
pub const CommandMachine = state.Machine(CommandState, CommandResult, struct {
    const Drive = state.Drive(CommandResult);
    pub fn drive(s: *CommandState) Drive {
        switch (s.*) {
            CommandState.Get => |*get_machine| {
                if (get_machine.drive()) |res| {
                    get_machine.deinit();
                    var res_val = res catch |err| return Drive{ .Complete = err };
                    if (res_val) |val| {
                        return Drive{ .Complete = map.Value.fromString(val) };
                    }
                    return Drive{ .Complete = map.Value.nil() };
                }
                return .Incomplete;
            },
            CommandState.Set => |*set_machine| {
                if (set_machine.drive()) |res| {
                    set_machine.deinit();
                    return Drive{ .Complete = res };
                }
                return .Incomplete;
            },
        }
    }
});

test "commands" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ga = try alloc.GlobalAllocator.init(50, arena.allocator());
    var la = alloc.LocalAllocator.init(&ga);
    var data: map.ExtendibleMap = undefined;
    try data.setup(1, arena.allocator(), &la);

    var respValueGet = (try resp.parseResp("*2\r\n+GET\r\n+key\r\n", 0, &la)).?;
    var listGet = respValueGet.value.asList().?;

    var respValueSet = (try resp.parseResp("*3\r\n+SET\r\n+key\r\n+value\r\n", 0, &la)).?;
    var listSet = respValueSet.value.asList().?;

    const commandGet = try CommandState.init(&data, listGet, &la);
    const commandSet = try CommandState.init(&data, listSet, &la);

    switch (commandGet) {
        CommandState.Get => {},
        else => unreachable,
    }

    switch (commandSet) {
        CommandState.Set => {},
        else => unreachable,
    }

    var setMachine = CommandMachine.init(commandSet);
    const setRes: map.Value = try setMachine.run();
    const expect = std.testing.expect;
    try expect(!setRes.isPresent());
    var getMachine = CommandMachine.init(commandGet);
    var getRes: map.Value = try getMachine.run();
    try expect(getRes.isPresent());
    var val_str = string.String.empty();
    val_str.append("value", &la).?;
    try expect(getRes.asString().?.eql(&val_str));
    arena.deinit();
}
