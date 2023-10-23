const std = @import("std");
const io = @import("io.zig");
const map = @import("map.zig");
const state = @import("state.zig");
const commands = @import("commands.zig");
const alloc = @import("alloc.zig");
const resp = @import("resp.zig");
const string = @import("string.zig");

const ExecutionState = struct {
    client: *io.ConnectionContext,
    data: *map.ExtendibleMap,
    allocator: *alloc.LocalAllocator,
    command: ?commands.CommandMachine = null,
    transaction: ?*commands.MultiMachine = null,
    transaction_prep: usize = 0,
    donothing: bool = false,
    calls: usize = 0,
};

pub fn transactionInt(machine: *ExecutionMachine) u64 {
    const ptr = if (machine.state.transaction) |t| t else return 1;
    const base: u64 = @intFromPtr(ptr);
    const txstate: u64 = if (machine.state.transaction_prep == 2) 1 else 0;
    return base | txstate;
}

pub fn recreateTransaction(machine: *ExecutionMachine, data: u64) void {
    if (data == 1) return;
    const one: u64 = 1;
    const ptrMask: u64 = ~one;
    const ptr: *commands.MultiMachine = @ptrFromInt(data & ptrMask);
    const prep: u64 = (data & 1) + 1;
    machine.state.transaction = ptr;
    machine.state.transaction_prep = prep;
}

const ExecutionMachine = state.Machine(ExecutionState, void, struct {
    pub fn drive(s: *ExecutionState) state.Drive(void) {
        s.calls += 1;
        const _100p = s.calls > 100;
        s.donothing = false;
        // Drive transaction
        // prep = 2 is driving
        // prep = 1 is reading commands
        if (s.transaction_prep == 2) {
            if (s.transaction) |command| {
                if (_100p) std.debug.print("Driving transaction, acqmach = {}, acq = {any}, i = {}\n", .{
                    command.state.acquiremachine != null,
                    command.state.shards.shards,
                    command.state.shards_acquired,
                });
                if (command.drive()) |res| {
                    if (res) {
                        _ = s.client.sendbuffer.push("+OK\r\n");
                    } else {
                        _ = s.client.sendbuffer.push("-OOM\r\n");
                    }
                    s.allocator.free(commands.MultiMachine, command);
                    s.transaction_prep = 0;
                    s.transaction = null;
                }
                return .Incomplete;
            }
        } else if (s.command) |*commandmachine| {
            if (commandmachine.drive()) |result| {
                if (result) |result_v| {
                    var mapv: commands.SingleCommandResult = result_v;
                    if (mapv.value.asConstString()) |str| {
                        const strlen = string.String.fromInt(@intCast(str.len()));
                        _ = s.client.sendbuffer.push("$");
                        _ = s.client.sendbuffer.push(strlen.sliceView());
                        _ = s.client.sendbuffer.push("\r\n");
                        _ = s.client.sendbuffer.push(str.sliceView());
                        _ = s.client.sendbuffer.push("\r\n");
                    } else if (mapv.executed == .Set) {
                        _ = s.client.sendbuffer.push("+OK\r\n");
                    } else if (mapv.executed == .Get) {
                        _ = s.client.sendbuffer.push("$-1\r\n"); // this valid :ok:
                    }
                    mapv.value.deinit(s.allocator);
                } else |err| {
                    _ = s.client.sendbuffer.push("-");
                    _ = s.client.sendbuffer.push(@errorName(err));
                    _ = s.client.sendbuffer.push("\r\n");
                }
                commandmachine.deinit();
                s.command = null;
                if (s.client.invalid) {
                    return .{ .Complete = {} };
                }
            }
            return .Incomplete;
        }
        if (s.client.invalid) {
            return .{ .Complete = {} };
        }

        if (s.client.recvbuffer.dataReady().len == 0) {
            s.donothing = true;
            return .Incomplete;
        }

        var resp_value = resp.parseResp(s.client.recvbuffer.dataReady(), 0, s.allocator) catch |err| {
            _ = s.client.sendbuffer.push("-");
            _ = s.client.sendbuffer.push(@errorName(err));
            _ = s.client.sendbuffer.push("\r\n");
            std.debug.print("Protocoll error: {s}\n", .{@errorName(err)});
            return .{ .Complete = {} };
        };

        if (resp_value) |v| {
            var vv = v;

            s.client.recvbuffer.dataConsumed(v.read_until);
            if (vv.value.asList()) |list| {
                var first = list.get(0);
                if (first.asString()) |f_str| {
                    // Manage transactions
                    //
                    if (s.transaction_prep == 1) {
                        var tx: *commands.MultiState = &s.transaction.?.state;

                        var exec = tx.addCommand(list.*) catch |err| {
                            _ = s.client.sendbuffer.push("-");
                            _ = s.client.sendbuffer.push(@errorName(err));
                            _ = s.client.sendbuffer.push("\r\n");
                            s.transaction_prep = 0;
                            var ptr: *commands.MultiMachine = s.transaction.?;
                            ptr.deinit();
                            s.allocator.free(commands.MultiMachine, ptr);
                            vv.value.deinit(s.allocator);
                            return .Incomplete;
                        };

                        if (exec) {
                            s.transaction_prep = 2;
                            return drive(s);
                        }

                        _ = s.client.sendbuffer.push("+QUEUED\r\n");
                        return .Incomplete;
                    } else if (std.mem.eql(u8, f_str.sliceView(), "MULTI")) {
                        // Begin transaction
                        if (s.allocator.allocate(commands.MultiMachine)) |machine| {
                            s.transaction_prep = 1;
                            machine.state = commands.MultiState.init(s.allocator, s.data);
                            s.transaction = machine;
                            _ = s.client.sendbuffer.push("+OK\r\n");
                            return .Incomplete;
                        } else {
                            _ = s.client.sendbuffer.push("-OOM\r\n");
                            return .Incomplete;
                        }
                    }
                }

                // the transaction takes ownership of vv.value so we cannot dealloc it if it was eaten.
                defer vv.value.deinit(s.allocator);
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
            vv.value.deinit(s.allocator);
            _ = s.client.sendbuffer.push("-Not a command\r\n");
        }
        return .Incomplete;
    }
});

fn EventLoop() type {
    return struct {
        const Node = struct {
            idx: usize,
            task: ExecutionMachine,
            next: ?*Node,
            prev: ?*Node,
        };

        size: usize,
        freeidxs: []usize,
        freeidx: usize,
        tasks: []Node,
        start: ?*Node,

        const This = @This();
        pub fn init(limit: usize, allocator: std.mem.Allocator) !This {
            var freeidxs = try allocator.alloc(usize, limit);
            for (0..limit) |i| {
                freeidxs[i] = i;
            }
            var tasks: []Node = try allocator.alloc(Node, limit);
            for (0..limit) |i| {
                tasks[i].next = null;
                tasks[i].prev = null;
            }
            return This{
                .size = 0,
                .freeidx = limit,
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
            node.prev = null;
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

const Config = struct {
    io_contexts: usize = 400,
    recv_buffer_size: usize = 1024,
    send_buffer_size: usize = 1024,
    queue_depth: usize = 1024,
    event_loop_limit: usize = 400,
    allocator_pages: usize = 50000,
    thread_count: usize = 1,
    max_expansions: usize = 16,
};

// TODO: Investigate random freezes this is just a remine its
fn worker(allocator: *alloc.GlobalAllocator, data: *map.ExtendibleMap, worker_id: usize, status: *std.atomic.Atomic(u64), config: Config) void {
    var la = alloc.LocalAllocator.init(allocator);
    var ctxpool = io.ContextPool.createPool(config.io_contexts, config.recv_buffer_size, config.send_buffer_size, std.heap.page_allocator) catch |err| {
        std.debug.print("#{} failed to allocate IO Context pool: {s}\n", .{ worker_id, @errorName(err) });
        std.os.exit(0);
    };
    var ring: io.IOServer = io.IOServer.init(ctxpool, @intCast(config.queue_depth), 3456) catch |err| {
        std.debug.print("#{} failed to setup IO Uring: {s}\n", .{ worker_id, @errorName(err) });
        std.os.exit(0);
    };
    var evt_loop = EventLoop().init(config.event_loop_limit, std.heap.page_allocator) catch |err| {
        std.debug.print("#{} failed to setup event loop: {s}\n", .{ worker_id, @errorName(err) });
        std.os.exit(0);
    };

    std.debug.print("#{} Ring started\n", .{worker_id});
    var wstatus = WorkerStatus{};
    var cansleep = true;

    while (true) {
        // report the worker status in an atomic int
        wstatus.sleep = cansleep;
        status.store(wstatus.toInt(), std.atomic.Ordering.Monotonic);

        // Process IO events
        while (ring.work(cansleep) catch |err| {
            std.debug.print("#{} IO Error: {s}\n", .{ worker_id, @errorName(err) });
            continue;
        }) |item| {
            cansleep = false; // dont sleep once we started
            if (item.lastevent == .Connected) {
                std.debug.print("#{} Accepted client on: {}\n", .{ worker_id, item.client_fd });
                if (evt_loop.claim()) |node| {
                    wstatus.connection_count += 1;
                    wstatus.event_loop += 1;
                    node.task = ExecutionMachine.init(ExecutionState{
                        .allocator = &la,
                        .client = item,
                        .data = data,
                    });
                } else {
                    ring.close(item) catch |err| {
                        std.debug.print("#{} Failed to deny connection: {s}\n", .{ worker_id, @errorName(err) });
                    };
                }
                continue;
            }

            // More data received
            if (item.lastevent == .Data) {
                // reschedule suspended event
                if (item.userdata != 0) {
                    const txdata = item.userdata;
                    item.userdata = 0;
                    if (evt_loop.claim()) |node| {
                        wstatus.event_loop += 1;

                        node.task = ExecutionMachine.init(ExecutionState{
                            .allocator = &la,
                            .client = item,
                            .data = data,
                        });
                        recreateTransaction(&node.task, txdata);
                    } else {
                        std.debug.print("#{} Failed to reschedule client: {}\n", .{ worker_id, item.client_fd });
                    }
                }
            }

            // Handle I/O Problems in suspended events
            if (item.lastevent == .Lost and item.userdata != 0) {
                var tmp = ExecutionMachine.init(ExecutionState{
                    .allocator = &la,
                    .client = item,
                    .data = data,
                });
                recreateTransaction(&tmp, item.userdata);
                if (tmp.state.transaction) |tx| {
                    tx.deinit();
                    la.free(commands.MultiMachine, tx);
                }
                std.debug.print("#{} Closing connection due to transmission: {}\n", .{ worker_id, item.client_fd });
                wstatus.connection_count -= 1;
                ring.close(item) catch |err| {
                    std.debug.print("#{} Failed to schedule close: {s}\n", .{ worker_id, @errorName(err) });
                };
            }
        }
        ring.submit() catch |err| {
            std.debug.print("#{} Failed to submit ring = {s}\n", .{ worker_id, @errorName(err) });
        };

        cansleep = true;
        var maybe_task = evt_loop.start;
        while (maybe_task) |task| {
            if (task.task.drive()) |_| {
                std.debug.print("#{} Closing connection because the task is completed: {}\n", .{ worker_id, task.task.state.client.client_fd });
                ring.close(task.task.state.client) catch |err| {
                    std.debug.print("#{} Failed to schedule close: {s}\n", .{ worker_id, @errorName(err) });
                };
                wstatus.event_loop -= 1;
                wstatus.connection_count -= 1;
                evt_loop.remove(task);
            } else if (task.task.state.donothing) {
                wstatus.event_loop -= 1;
                task.task.state.client.userdata = transactionInt(&task.task); // Wait for more data - remove from scheduler
                evt_loop.remove(task);
            } else {
                cansleep = false;
                ring.send(task.task.state.client) catch |err| {
                    std.debug.print("#{} Failed to send data = {s}\n", .{ worker_id, @errorName(err) });
                };
            }
            maybe_task = task.next;
        }

        ring.submit() catch |err| {
            std.debug.print("#{} Failed to submit ring = {s}\n", .{ worker_id, @errorName(err) });
        };
    }
}

fn seql(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or a[0] != '-') return false;
    return std.mem.eql(u8, a[1..a.len], b);
}

const WorkerStatus = struct {
    sleep: bool = false,
    connection_count: u64 = 0,
    event_loop: u64 = 0,

    pub fn fromInt(i: u64) WorkerStatus {
        var data = i;
        var w: WorkerStatus = undefined;
        w.sleep = data & 1 == 1;
        data >>= 1;
        w.connection_count = (data & 0b1111111111);
        data >>= 10;
        w.event_loop = (data & 0b1111111111);
        data >>= 10;
        return w;
    }

    pub fn toInt(this: WorkerStatus) u64 {
        var data: u64 = 0;
        data += this.event_loop;
        data <<= 10;
        data += this.connection_count;
        data <<= 1;
        data |= @intFromBool(this.sleep);
        return data;
    }
};

pub fn main() !void {
    var config: Config = .{};

    var i: usize = 1;
    while (i < std.os.argv.len) : (i += 1) {
        const argsize = std.mem.indexOfSentinel(u8, 0, std.os.argv[i]);
        const arg = std.os.argv[i][0..argsize];

        std.debug.print("Arg: '{s}'\n", .{arg});

        var size_ptr: ?*usize = if (seql(arg, "threads"))
            &config.thread_count
        else if (seql(arg, "allocator-pages"))
            &config.allocator_pages
        else if (seql(arg, "event-loop-limit"))
            &config.event_loop_limit
        else if (seql(arg, "io-contexts"))
            &config.io_contexts
        else if (seql(arg, "uring-depth"))
            &config.queue_depth
        else if (seql(arg, "recv-buffer-size"))
            &config.recv_buffer_size
        else if (seql(arg, "send-buffer-size"))
            &config.send_buffer_size
        else if (seql(arg, "max-expansions"))
            &config.max_expansions
        else
            null;

        if (size_ptr) |ptr| {
            i += 1;
            if (i >= std.os.argv.len) {
                size_ptr = null;
            } else {
                const numargsize = std.mem.indexOfSentinel(u8, 0, std.os.argv[i]);
                const numarg = std.os.argv[i][0..numargsize];
                std.debug.print("Num: '{s}'\n", .{numarg});

                if (std.fmt.parseInt(usize, numarg, 10)) |num| {
                    ptr.* = num;
                } else |_| {
                    size_ptr = null;
                }
            }
        }

        if (size_ptr == null) {
            std.debug.print(
                \\ Command use
                \\
                \\ -threads
                \\     The amount of threads that are used.
                \\
                \\ -io-contexts
                \\     The number of allocated io-contexts per thread managed to controll one connection.
                \\     If a thread has no more io-contexts and would need to open a connection it must refuse.
                \\
                \\ -recv-buffer-size
                \\     The buffer size allocated per io-context to recieve data. This currently limits the command size.
                \\
                \\ -send-buffer-size
                \\     The buffer size allocated per io-context used to send data. This currently limits the response size.
                \\
                \\ -event-loop-limit
                \\      The size of the event loop.
                \\      Each thread has one event loop that manages concurrently running transactions.
                \\      If the event loop is full no further transactions can be scheduled on the thread.
                \\
                \\ -allocator-pages
                \\      The amount of 32KiB pages to be used for userdata.
                \\      This is the only dynamic memory available inside the DB, if all pages are used up it will cause failed allocations. 
                \\
                \\ -uring-depth
                \\     The size of the io_uring queue used for I/O. Must be power of two.
                \\
                \\ -max-expansions
                \\     The number of expansions (doubling) of entry count.
                \\
            , .{});
            return;
        }
    }

    var ga = try alloc.GlobalAllocator.init(config.allocator_pages, std.heap.page_allocator);
    var la = alloc.LocalAllocator.init(&ga);

    var data: map.ExtendibleMap = undefined;
    try data.setup(config.max_expansions, std.heap.page_allocator, &la);

    var threads: [10000]std.Thread = undefined; // who cares
    var status: [10000]std.atomic.Atomic(u64) = undefined;
    for (0..config.thread_count) |thread_num| {
        std.debug.print("Spawning thread nr. {}\n", .{thread_num});
        status[thread_num] = std.atomic.Atomic(u64).init(0);
        threads[thread_num] = std.Thread.spawn(.{}, worker, .{ &ga, &data, thread_num, &status[thread_num], config }) catch |err| {
            std.debug.print("Failed to spawn thread: {s}\n", .{@errorName(err)});
            std.os.exit(1);
        };
    }

    var arr = [1]u8{0};
    while (true) {
        _ = try std.io.getStdIn().read(&arr);
        for (0..config.thread_count) |thread| {
            const w = status[thread].load(std.atomic.Ordering.Monotonic);
            const wstatus = WorkerStatus.fromInt(w);
            std.debug.print("Thread {}, sleep = {}, connections = {}, event loop = {}\n", .{ thread, wstatus.sleep, wstatus.connection_count, wstatus.event_loop });
        }
    }

    threads[0].join();
}
