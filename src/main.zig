const std = @import("std");
const io = @import("io.zig");
const map = @import("map.zig");
const state = @import("state.zig");
const commands = @import("commands.zig");
const alloc = @import("alloc.zig");
const resp = @import("resp.zig");

const ExecutionState = struct {
    client: *io.ConnectionContext,
    data: *map.ExtendibleMap,
    allocator: *alloc.LocalAllocator,
    command: ?commands.CommandMachine = null,
    donothing: bool = false,
};

const ExecutionMachine = state.Machine(ExecutionState, void, struct {
    pub fn drive(s: *ExecutionState) state.Drive(void) {
        s.donothing = false;
        if (s.command) |*commandmachine| {
            if (commandmachine.drive()) |result| {
                if (result) |result_v| {
                    var mapv: map.Value = result_v;
                    if (mapv.asConstString()) |str| {
                        _ = s.client.sendbuffer.push("+");
                        _ = s.client.sendbuffer.push(str.sliceView());
                        _ = s.client.sendbuffer.push("\r\n");
                    } else {
                        _ = s.client.sendbuffer.push("+OK\r\n");
                    }
                    mapv.deinit(s.allocator);
                } else |err| {
                    _ = s.client.sendbuffer.push("-");
                    _ = s.client.sendbuffer.push(@errorName(err));
                    _ = s.client.sendbuffer.push("\r\n");
                }
                commandmachine.deinit();
                s.command = null;
                return .Incomplete;
            }
        }
        if (s.client.invalid) {
            return .{ .Complete = {} };
        }

        if (s.client.recvbuffer.dataReady().len == 0) {
            // s.donothing = true; TODO: Figure out why I/O Suspension is broke
            return .Incomplete;
        }

        var resp_value = resp.parseResp(s.client.recvbuffer.dataReady(), 0, s.allocator) catch |err| {
            _ = s.client.sendbuffer.push("-");
            _ = s.client.sendbuffer.push(@errorName(err));
            _ = s.client.sendbuffer.push("\r\n");
            return .{ .Complete = {} };
        };
        if (resp_value) |v| {
            var vv = v;
            s.client.recvbuffer.dataConsumed(v.read_until);
            if (vv.value.asList()) |list| {
                var vlist = list;

                if (commands.CommandState.init(s.data, vlist, s.allocator)) |comm_state| {
                    const command = commands.CommandMachine.init(comm_state);
                    s.command = command;
                    return drive(s);
                } else |err| {
                    _ = s.client.sendbuffer.push("-");
                    _ = s.client.sendbuffer.push(@errorName(err));
                    _ = s.client.sendbuffer.push("\r\n");
                }
                return .Incomplete;
            }
            _ = s.client.sendbuffer.push("-Not a command\r\n");
        }
        return .Incomplete;
    }
});

fn EventLoop(comptime Size: usize) type {
    return struct {
        const Node = struct {
            idx: usize,
            task: ExecutionMachine,
            next: ?*Node,
            prev: ?*Node,
        };

        size: usize,
        freeidxs: [Size]usize,
        freeidx: usize,
        tasks: [Size]Node,
        start: ?*Node,

        const This = @This();
        pub fn init() This {
            var freeidxs: [Size]usize = undefined;
            for (0..Size) |i| {
                freeidxs[i] = i;
            }
            var tasks: [Size]Node = undefined;
            for (0..Size) |i| {
                tasks[i].next = null;
                tasks[i].prev = null;
            }
            return This{
                .size = 0,
                .freeidx = Size,
                .freeidxs = freeidxs,
                .tasks = tasks,
                .start = null,
            };
        }

        pub fn claim(this: *This) ?*Node {
            if (this.freeidx == 0) return null;
            this.freeidx -= 1;
            const idx = this.freeidxs[this.freeidx];
            var node = &this.tasks[idx];
            node.idx = idx;
            if (this.start) |start| {
                node.next = start;
                start.prev = node;
            }
            this.start = node;
            return node;
        }

        pub fn iter(this: *This) ?*Node {
            return this.start;
        }

        pub fn remove(this: *This, node: *Node) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                this.start = node.next;
            }
            if (node.next) |next| {
                next.prev = node.prev;
            }
            this.freeidxs[this.freeidx] = node.idx;
            this.freeidx += 1;
        }
    };
}

pub fn main() !void {
    var ctxpool = try io.ContextPool.createPool(400, 1024, 1024, std.heap.page_allocator);
    var ring: io.IOServer = try io.IOServer.init(ctxpool, 1024, 3456);

    var ga = try alloc.GlobalAllocator.init(50000, std.heap.page_allocator);
    var la = alloc.LocalAllocator.init(&ga);

    var data: map.ExtendibleMap = undefined;
    try data.setup(16, std.heap.page_allocator, &la);
    var evt_loop = EventLoop(400).init();

    std.debug.print("Ring started\n", .{});

    // simple IO Uring echo server
    var cansleep = true;
    while (true) {
        while (ring.work(cansleep) catch |err| {
            std.debug.print("IO Error: {s}\n", .{@errorName(err)});
            continue;
        }) |item| {
            cansleep = false; // dont sleep once we started
            if (item.lastevent == .Connected) {
                std.debug.print("Accepted client on: {}\n", .{item.client_fd});
                if (evt_loop.claim()) |node| {
                    node.task = ExecutionMachine.init(ExecutionState{
                        .allocator = &la,
                        .client = item,
                        .data = &data,
                    });
                } else {
                    ring.close(item) catch |err| {
                        std.debug.print("Failed to deny connection: {s}\n", .{@errorName(err)});
                    };
                }
                continue;
            }
            if (item.lastevent == .Data) {
                if (item.userdata == 1) {
                    item.userdata = 0;
                    if (evt_loop.claim()) |node| {
                        node.task = ExecutionMachine.init(ExecutionState{
                            .allocator = &la,
                            .client = item,
                            .data = &data,
                        });
                    } else {
                        std.debug.print("Failed to reschedule client: {}\n", .{item.client_fd});
                    }
                }
            }
            if (item.lastevent == .Lost and item.userdata == 1) {
                std.debug.print("Closing connection: {}\n", .{item.client_fd});
                ring.close(item) catch |err| {
                    std.debug.print("Failed to schedule close: {s}\n", .{@errorName(err)});
                };
            }
        }
        ring.submit() catch |err| {
            std.debug.print("Failed to submit ring = {s}\n", .{@errorName(err)});
        };

        cansleep = true;
        var maybe_task = evt_loop.start;
        while (maybe_task) |task| {
            if (task.task.drive()) |_| {
                std.debug.print("Closing connection: {}\n", .{task.task.state.client.client_fd});
                ring.close(task.task.state.client) catch |err| {
                    std.debug.print("Failed to schedule close: {s}\n", .{@errorName(err)});
                };
                evt_loop.remove(task);
            } else if (task.task.state.donothing) {
                task.task.state.client.userdata = 1; // Wait for more data - remove from scheduler
                evt_loop.remove(task);
            } else {
                cansleep = false;
                ring.send(task.task.state.client) catch |err| {
                    std.debug.print("Failed to send data = {s}\n", .{@errorName(err)});
                };
            }
            maybe_task = task.next;
        }

        ring.submit() catch |err| {
            std.debug.print("Failed to submit ring = {s}\n", .{@errorName(err)});
        };
    }
}
