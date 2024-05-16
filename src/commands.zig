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
    now: u32,
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

const GetMachine = state.DepMachine(GetState, GetResult, map.ExtendibleMap.ReadArgs, struct {
    const Drive = state.Drive(GetResult);
    pub fn drive(s: *GetState, dep: map.ExtendibleMap.ReadArgs) Drive {
        var maybe_val = dep.smallmap.get(s.hash, &s.key, s.now, dep.validator);
        if (maybe_val) |val| {
            if (!dep.validator.validate()) {
                return Drive{ .Complete = null };
            }
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
    expire: u32,
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
                value.expires.* = s.expire;
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

const MaxShards = 16; // Hardcode for now... ._.

pub const MultiState = struct {
    allocator: *alloc.LocalAllocator,
    data: *map.ExtendibleMap,

    acquired: [MaxShards]map.ExtendibleMap.MAcquireItem = [_]map.ExtendibleMap.MAcquireItem{.{ .slot = null, .hash = 0, .lock = null }} ** MaxShards,
    commands: [MaxShards]resp.RespList = undefined,
    rollbacks: [MaxShards]?struct {
        value: map.Value,
        expires: u32,
    } = .{null} ** MaxShards,
    rollback: bool = false,
    release: bool = false,
    command_count: usize = 0,
    commands_executed: usize = 0,
    shards_acquired: usize = 0,
    calls: usize = 0,

    splitmachine: ?map.ExtendibleMap.SplitMachine = null,
    acquiremachine: ?map.ExtendibleMap.MAcquireMachine = null,
    now: u32,

    const This = @This();

    pub fn init(la: *alloc.LocalAllocator, data: *map.ExtendibleMap, now: u32) This {
        return .{
            .allocator = la,
            .data = data,
            .now = now,
        };
    }

    pub fn addCommand(this: *This, c_command: resp.RespList) !bool {
        var command = c_command;
        if (command.length < 1) {
            return error.InvalidArgumentCount;
        }
        if (command.get(0).asString()) |cmd_str| {
            const slice_view = cmd_str.sliceView();
            if (std.mem.eql(u8, slice_view, "GET")) {
                // GET
                if (command.length != 2) return error.InvalidArgumentCount;
                if (command.get(1).asString() == null) return error.InvalidArguments;
                this.acquired[this.command_count].hash = command.get(1).asString().?.hash();
                this.commands[this.command_count] = command;
                this.command_count += 1;
                return false;
            } else if (std.mem.eql(u8, slice_view, "SET")) {
                if (command.length != 3) return error.InvalidArgumentCount;
                if (command.get(1).asString() == null) return error.InvalidArguments;
                if (command.get(2).asString() == null) return error.InvalidArguments;
                this.acquired[this.command_count].hash = command.get(1).asString().?.hash();
                this.commands[this.command_count] = command;
                this.command_count += 1;
                return false;
            } else if (std.mem.eql(u8, slice_view, "SETEX")) {
                if (command.length != 4) return error.InvalidArgumentCount;
                if (command.get(1).asString() == null) return error.ExpectedKeyAsStr;
                if (command.get(2).asString() == null or command.get(2).asString().?.toInt() == null) return error.ExpectedExpiryAsInt;
                if (command.get(3).asString() == null) return error.ExpectedValAsStr;
                this.acquired[this.command_count].hash = command.get(1).asString().?.hash();
                this.commands[this.command_count] = command;
                this.command_count += 1;
                return false;
            } else if (std.mem.eql(u8, slice_view, "EXEC")) {
                command.deinit(this.allocator);
                this.acquiremachine = this.data.multi_acquire(this.command_count, &this.acquired);
                return true;
            }
            return error.UnsupportedCommand;
        }
        return error.InvalidArgumentCount;
    }
};

pub const MultiMachine = state.Machine(MultiState, bool, struct {
    pub fn drive(s: *MultiState) state.Drive(bool) {
        s.calls += 1;
        if (s.release) {
            // Step 3: Release all the shards held by the transaction
            //
            var shard: usize = 0;
            while (s.acquired[shard].lock) |acquired| : (shard += 1) {
                if (shard > 0 and s.acquired[shard - 1].lock.? == acquired) continue;
                acquired.unlock();
            }

            for (0..s.commands_executed) |i| {
                if (s.rollbacks[i]) |v| {
                    var vv = v;
                    vv.value.deinit(s.allocator);
                }
            }

            for (0..s.command_count) |i| {
                s.commands[i].deinit(s.allocator);
            }
            // if we didn't have to roolback, this was a great trip...
            return state.Drive(bool){ .Complete = !s.rollback };
        } else if (s.rollback) {
            // Maybe step 2.5: Rollback
            while (true) {
                // we are hot, we own everything, this is faster than anoying the event loop.
                // (maybe maybe maybe, just dont crash transactions ._.)

                if (s.commands_executed == 0) {
                    s.release = true;
                    return drive(s);
                }
                s.commands_executed -= 1;

                // undo the commands
                if (s.rollbacks[s.commands_executed]) |*v| {
                    var command = s.commands[s.commands_executed];
                    var str = command.get(1).asString().?;
                    const shash = str.hash();
                    var small_map = s.data.multi_get_map(shash);
                    if (v.value.asString()) |str_val| {
                        var res = small_map.updateOrCreate(shash, str.*, s.now, s.allocator);
                        switch (res) {
                            map.SmallMap.Result.Present => |val| {
                                val.value.deinit(s.allocator);
                                val.value.* = map.Value.fromString(str_val.*);
                            },
                            map.SmallMap.Result.Absent => unreachable,
                            map.SmallMap.Result.Split => unreachable,
                            map.SmallMap.Result.Expired => unreachable,
                        }
                        command.get(1).* = resp.RespValue.from({});
                        command.deinit(s.allocator);
                    } else if (!v.value.isPresent()) {
                        if (small_map.delete(shash, str, s.now)) |cold| {
                            var old = cold;
                            old.entry.key.deinit(s.allocator);
                            old.entry.value.deinit(s.allocator);
                        }
                        command.deinit(s.allocator);
                    }
                }
            }
        } else if (s.acquiremachine) |*acquiremachine| {
            // Step 1.1: Run the shard acquiring machine
            //
            if (acquiremachine.drive()) |_| {
                s.shards_acquired = s.command_count;
                s.acquiremachine = null;
                s.calls = 0;
            }
            if (s.calls < 128) {
                return drive(s);
            }
            return .Incomplete;
        }
        if (s.splitmachine) |*split_machine| {
            // Step 2.1 Split the map we want to insert into
            //
            if (split_machine.drive()) |whoops_acquired| {
                s.acquired[s.shards_acquired] = map.ExtendibleMap.MAcquireItem{
                    .hash = 0,
                    .lock = whoops_acquired.lock,
                    .slot = null,
                };
                s.shards_acquired += 1;
                s.splitmachine = null;
                s.calls = 0;
            }
            if (s.calls < 128) {
                return drive(s);
            }
            return .Incomplete;
        } else if (s.commands_executed < s.command_count) {
            // Step 2. Execute the command
            //
            var command = s.commands[s.commands_executed];
            const execute = command.get(0).asString().?;
            var str = command.get(1).asString().?;
            const shash = str.hash();
            var small_map = s.data.multi_get_map(shash);

            // currently only SET supported in multi.
            //
            // It is not about what is done, but what could be done...
            if (std.mem.eql(u8, execute.sliceView(), "SET") or std.mem.eql(u8, execute.sliceView(), "SETEX")) {
                var res = small_map.updateOrCreate(shash, str.*, 0, s.allocator);
                var expires: u32 = 0;
                var val_idx: usize = 2;
                if (std.mem.eql(u8, execute.sliceView(), "SETEX")) {
                    expires = @intCast(command.get(2).asString().?.toInt().?);
                    expires += s.now;
                    val_idx = 3;
                }
                switch (res) {
                    map.SmallMap.Result.Present => |val| {
                        s.rollbacks[s.command_count] = .{
                            .value = val.value.*,
                            .expires = val.expires.*,
                        };
                        val.value.* = map.Value.fromString(command.get(val_idx).asString().?.*);
                        val.expires.* = expires;
                        s.commands_executed += 1;
                    },
                    map.SmallMap.Result.Absent => |val| {
                        s.rollbacks[s.command_count] = null;
                        val.value.* = map.Value.fromString(command.get(val_idx).asString().?.*);
                        val.expires.* = expires;
                        command.get(val_idx).* = resp.RespValue.from({});
                        s.commands_executed += 1;
                    },
                    map.SmallMap.Result.Expired => |val| {
                        s.rollbacks[s.command_count] = null;
                        val.value.deinit(s.allocator);
                        val.value.* = map.Value.fromString(command.get(val_idx).asString().?.*);
                        val.expires.* = expires;
                        s.commands_executed += 1;
                    },
                    map.SmallMap.Result.Split => {
                        if (s.data.split(shash, small_map, s.allocator)) |split_machine| {
                            s.splitmachine = split_machine;
                            return drive(s);
                        } else {
                            s.rollback = true;
                        }
                    },
                }
                return drive(s);
            } else {
                s.commands_executed += 1;
            }
            return .Incomplete;
        }
        // Step 3 done
        s.release = true;
        return drive(s);
    }

    pub fn deinit(this: *MultiState) void {
        for (0..this.command_count) |i| {
            this.commands[i].deinit(this.allocator);
        }
    }
});

pub const CommandError = error{
    UnsupportedCommand,
    InvalidArgumentCount,
    InvalidCommandFormat,
    InvalidArguments,
    TypeNotTrivialReadable,
    OutOfMemory,
    ExpectedValToBeString,
    ExpectedKeyToBeString,
    ExpectedExpireToBeInt,
};

pub const CommandState = union(enum) {
    Set: SetMachine,
    Get: ExGetMachine,

    pub fn init(data: *map.ExtendibleMap, command: *resp.RespList, now: u32, la: *alloc.LocalAllocator) !CommandState {
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
                            .now = now,
                        })),
                    ),
                };
            } else if (std.mem.eql(u8, slice_view, "SET") or std.mem.eql(u8, slice_view, "SETEX")) {
                const cmd_len: usize = if (std.mem.eql(u8, slice_view, "SETEX")) 4 else 3;
                if (command.length != cmd_len) return error.InvalidArgumentCount;
                var key: string.String = string.String.empty();
                var value: string.String = string.String.empty();
                var expires: u32 = 0;
                var val_idx: usize = 2;
                if (std.mem.eql(u8, slice_view, "SETEX")) {
                    if (command.get(2).asString()) |val| {
                        expires = @intCast(val.toInt() orelse return error.ExpectedExpireToBeInt);
                        expires += now;
                    } else return error.ExpectedExpireToBeInt;
                    val_idx = 3;
                }

                if (command.get(1).asString()) |key_str| key = key_str.* else return error.ExpectedKeyToBeString;
                if (command.get(val_idx).asString()) |val_str| value = val_str.* else return error.ExpectedValToBeString;
                command.get(1).* = resp.RespValue.from({});
                command.get(val_idx).* = resp.RespValue.from({});

                const insState = map.InsertAndSplitState.init(
                    key,
                    data,
                    now,
                    la,
                );
                return CommandState{
                    .Set = SetMachine.init(SetState{
                        .value = map.Value.fromString(value),
                        .ins_spl_machine = map.InsertAndSplitMachine.init(insState),
                        .expire = expires,
                    }),
                };
            }
            return error.UnsupportedCommand;
        }
        return error.InvalidArgumentCount;
    }
};

pub const SingleCommandResult = struct {
    executed: enum {
        Get,
        Set,
        Multi,
    },
    value: map.Value,
};

pub const CommandResult = CommandError!SingleCommandResult;
pub const CommandMachine = state.Machine(CommandState, CommandResult, struct {
    const Drive = state.Drive(CommandResult);
    pub fn drive(s: *CommandState) Drive {
        switch (s.*) {
            CommandState.Get => |*get_machine| {
                if (get_machine.drive()) |res| {
                    get_machine.deinit();
                    var res_val = res catch |err| return Drive{ .Complete = err };
                    if (res_val) |val| {
                        return Drive{ .Complete = .{ .executed = .Get, .value = map.Value.fromString(val) } };
                    }
                    return Drive{ .Complete = .{ .executed = .Get, .value = map.Value.nil() } };
                }
                return .Incomplete;
            },
            CommandState.Set => |*set_machine| {
                if (set_machine.drive()) |res| {
                    set_machine.deinit();
                    if (res) |mapv| {
                        return Drive{ .Complete = .{ .executed = .Set, .value = mapv } };
                    } else |err| {
                        return Drive{ .Complete = err };
                    }
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
    const setRes: SingleCommandResult = try setMachine.run();
    const expect = std.testing.expect;
    try expect(!setRes.value.isPresent());
    var getMachine = CommandMachine.init(commandGet);
    var getRes: SingleCommandResult = try getMachine.run();
    try expect(getRes.value.isPresent());
    var val_str = string.String.empty();
    val_str.append("value", &la).?;
    try expect(getRes.value.asString().?.eql(&val_str));
    arena.deinit();
}

test "commands.Multi" {
    const expect = std.testing.expect;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ga = try alloc.GlobalAllocator.init(50, arena.allocator());
    var la = alloc.LocalAllocator.init(&ga);
    var data: map.ExtendibleMap = undefined;
    try data.setup(1, arena.allocator(), &la);

    var respValueSet1 = (try resp.parseResp("*3\r\n+SET\r\n+key1\r\n+value1\r\n", 0, &la)).?;
    var listSet1 = respValueSet1.value.asList().?.*;

    var respValueSet = (try resp.parseResp("*3\r\n+SET\r\n+key\r\n+value\r\n", 0, &la)).?;
    var listSet = respValueSet.value.asList().?.*;

    var respValueExec = (try resp.parseResp("*1\r\n+EXEC\r\n", 0, &la)).?;
    var listExec = respValueExec.value.asList().?.*;

    var multi = MultiState.init(&la, &data);
    try expect(!try multi.addCommand(listSet1));
    try expect(!try multi.addCommand(listSet));
    try expect(try multi.addCommand(listExec));

    var multiMachine = MultiMachine.init(multi);
    try expect(multiMachine.run());

    arena.deinit();
}
