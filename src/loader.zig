const io = @import("io.zig");
const string = @import("string.zig");
const std = @import("std");

const okBytes = 5;
const queuedBytes = 9;

const listHead = 4;

const Config = struct {
    connections: usize = 12,
    recv_buffer_size: usize = 1024,
    send_buffer_size: usize = 1024,
    queue_depth: usize = 1024,
    thread_count: usize = 4,
    port: usize = 3456,
    dbtype: usize = 0,
    payload: usize = 0,
};

const ReportSlice = []u32;

fn countLines(data: []u8) u32 {
    var c: u32 = 0;
    for (data) |d| {
        if (d == '\n') c += 1;
    }
    return c;
}

fn worker(worker_id: usize, config: Config, signal: *std.atomic.Atomic(u32), report: ReportSlice) void {
    // setaffinity(worker_id, config.affinity_spacing) catch {
    //     std.debug.print("Couldn't set affinity\n", .{});
    //     std.os.exit(0);
    // };

    var ctxpool = io.ContextPool.createPool(
        config.connections,
        config.recv_buffer_size,
        config.send_buffer_size,
        std.heap.page_allocator,
    ) catch |err| {
        std.debug.print("#{} failed to allocate IO Context pool: {s}\n", .{ worker_id, @errorName(err) });
        std.os.exit(0);
    };
    var ring: io.IOServer = io.IOServer.init(ctxpool, @intCast(config.queue_depth)) catch |err| {
        std.debug.print("#{} failed to setup IO Uring: {s}\n", .{ worker_id, @errorName(err) });
        std.os.exit(0);
    };
    var rnd = std.rand.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    for (0..config.connections) |_| {
        ring.connect(0, @intCast(config.port)) catch |err| {
            std.debug.print("#{} failed to prepare open connection: {s}\n", .{ worker_id, @errorName(err) });
            std.os.exit(0);
        };
    }
    var count: u32 = 0;
    var cansleep = true;
    const start: u64 = @intCast(std.time.microTimestamp());
    while (true) {
        var status = signal.load(std.atomic.Ordering.Monotonic);
        if (status == 2) {
            report[999_999] = count;
            return;
        }

        var iterator = ring.work(cansleep) catch |err| {
            std.debug.print("#{} failed to drive I/O: {s}\n", .{ worker_id, @errorName(err) });
            std.os.exit(0);
        };
        var now: u64 = @intCast(std.time.microTimestamp());
        now -= start;

        while (iterator.next() catch |err| {
            std.debug.print("#{} IO Error: {s}\n", .{ worker_id, @errorName(err) });
            continue;
        }) |item| {
            if (item.lastevent == io.IOEvent.Open) {
                var lines = sendPayload(item, config.payload, config.dbtype, &rnd);
                item.userdata = now + (lines << 32);
                ring.send(item) catch |err| {
                    std.debug.print("#{} failed to send I/O: {s}\n", .{ worker_id, @errorName(err) });
                    std.os.exit(0);
                };
                ring.recv(item) catch |err| {
                    std.debug.print("#{} failed to schedule read I/O: {s}\n", .{ worker_id, @errorName(err) });
                    std.os.exit(0);
                };
            } else if (item.lastevent == io.IOEvent.Data) {
                if (countLines(item.recvbuffer.dataReady()) == item.userdata >> 32) {
                    item.recvbuffer.dataConsumed(item.recvbuffer.dataReady().len);
                    const delta = now - (item.userdata & ((1 << 32) - 1));
                    if (status == 1) {
                        count += 1;
                        report[@intCast(@min(999_998, delta))] += 1;
                    }
                    if (item.is_sending) {
                        item.userdata = 0;
                    } else {
                        var lines = sendPayload(item, config.payload, config.dbtype, &rnd);
                        item.userdata = now + (lines << 32);
                        ring.send(item) catch |err| {
                            std.debug.print("#{} failed to send I/O: {s}\n", .{ worker_id, @errorName(err) });
                            std.os.exit(0);
                        };
                    }
                }
            } else if (item.lastevent == io.IOEvent.Write) {
                if (item.userdata == 0) {
                    var lines = sendPayload(item, config.payload, config.dbtype, &rnd);
                    item.userdata = now + (lines << 32);
                    ring.send(item) catch |err| {
                        std.debug.print("#{} failed to send I/O: {s}\n", .{ worker_id, @errorName(err) });
                        std.os.exit(0);
                    };
                }
            } else if (item.lastevent == io.IOEvent.Lost) {
                std.debug.print("#{} Connection dropped\n", .{worker_id});
                std.os.exit(0);
            } else {
                std.debug.print("Unhandled status: {}\n", .{item.lastevent});
            }
        }
    }
}

fn normal(rnd: *std.rand.Random) i64 {
    return @intFromFloat((((rnd.float(f64) + rnd.float(f64) + rnd.float(f64))) / 3) * 89_999_999 + 10_000_00);
}

fn sendPayload(ctx: *io.ConnectionContext, payload_type: usize, dbtype: usize, rnd: *std.rand.DefaultPrng) u64 {
    var srand = rnd.random();
    var r = &srand;
    if (payload_type == 0) {
        //SET
        for (0..8) |_| {
            _ = ctx.sendbuffer.push("*3\r\n$3\r\nSET\r\n$8\r\n");
            const key: i64 = @intCast(rnd.next() % 89_999_999 + 10_000_000);
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n$8\r\n");
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n");
        }
        return 8;
    } else if (payload_type == 1) {
        // GET/SET P8 G
        for (0..8) |_| {
            if (rnd.next() % 10 == 2) {
                _ = ctx.sendbuffer.push("*3\r\n$3\r\nSET\r\n$8\r\n");
                const key: i64 = normal(r);
                _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
                _ = ctx.sendbuffer.push("\r\n$8\r\n");
                _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
                _ = ctx.sendbuffer.push("\r\n");
            } else {
                _ = ctx.sendbuffer.push("*2\r\n$3\r\nGET\r\n$8\r\n");
                const key: i64 = normal(r);
                _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
                _ = ctx.sendbuffer.push("\r\n");
            }
        }
        return 8;
    } else if (payload_type == 2) {
        // GET/SET P1 G
        if (rnd.next() % 10 == 0) {
            _ = ctx.sendbuffer.push("*3\r\n$3\r\nSET\r\n$8\r\n");
            const key: i64 = normal(r);
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n$8\r\n");
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n");
        } else {
            _ = ctx.sendbuffer.push("*2\r\n$3\r\nGET\r\n$8\r\n");
            const key: i64 = normal(r);
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n");
        }
        return 1;
    } else if (payload_type == 3) {
        // GET/SET P8 R
        for (0..8) |_| {
            if (rnd.next() % 10 == 2) {
                _ = ctx.sendbuffer.push("*3\r\n$3\r\nSET\r\n$8\r\n");
                const key: i64 = @intCast(rnd.next() % 89_999_999 + 10_000_000);
                _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
                _ = ctx.sendbuffer.push("\r\n$8\r\n");
                _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
                _ = ctx.sendbuffer.push("\r\n");
            } else {
                _ = ctx.sendbuffer.push("*2\r\n$3\r\nGET\r\n$8\r\n");
                const key: i64 = @intCast(rnd.next() % 89_999_999 + 10_000_000);
                _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
                _ = ctx.sendbuffer.push("\r\n");
            }
        }
        return 8;
    } else if (payload_type == 4) {
        // GET/SET P1 R
        if (rnd.next() % 10 == 0) {
            _ = ctx.sendbuffer.push("*3\r\n$3\r\nSET\r\n$8\r\n");
            const key: i64 = @intCast(rnd.next() % 89_999_999 + 10_000_000);
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n$8\r\n");
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n");
        } else {
            _ = ctx.sendbuffer.push("*2\r\n$3\r\nGET\r\n$8\r\n");
            const key: i64 = @intCast(rnd.next() % 89_999_999 + 10_000_000);
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n");
        }
        return 1;
    } else if (payload_type == 5) {
        // SET/GET P1 G
        if (rnd.next() % 10 == 0) {
            _ = ctx.sendbuffer.push("*2\r\n$3\r\nGET\r\n$8\r\n");
            const key: i64 = normal(r);
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n");
        } else {
            _ = ctx.sendbuffer.push("*3\r\n$3\r\nSET\r\n$8\r\n");
            const key: i64 = normal(r);
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n$8\r\n");
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n");
        }
        return 1;
    } else if (payload_type == 6) {
        // SET/GET P1 R
        if (rnd.next() % 10 == 0) {
            _ = ctx.sendbuffer.push("*2\r\n$3\r\nGET\r\n$8\r\n");
            const key: i64 = @intCast(rnd.next() % 89_999_999 + 10_000_000);
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n");
        } else {
            _ = ctx.sendbuffer.push("*3\r\n$3\r\nSET\r\n$8\r\n");
            const key: i64 = @intCast(rnd.next() % 89_999_999 + 10_000_000);
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n$8\r\n");
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n");
        }
        return 1;
    } else if (payload_type == 7) {
        _ = ctx.sendbuffer.push("*1\r\n$5\r\nMULTI\r\n");
        for (0..5) |_| {
            _ = ctx.sendbuffer.push("*3\r\n$3\r\nSET\r\n$8\r\n");
            const key: i64 = @intCast(rnd.next() % 89_999_999 + 10_000_000);
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n$8\r\n");
            _ = ctx.sendbuffer.push(string.String.fromInt(key).sliceView());
            _ = ctx.sendbuffer.push("\r\n");
        }
        _ = ctx.sendbuffer.push("*1\r\n$4\r\nEXEC\r\n");
        if (dbtype == 0) {
            return 7;
        } else {
            return 12;
        }
    }
    std.debug.print("Invalid payload\n", .{});
    std.os.exit(1);
}

fn seql(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or a[0] != '-') return false;
    return std.mem.eql(u8, a[1..a.len], b);
}

pub fn main() !void {
    var config: Config = .{};

    var argi: usize = 1;
    while (argi < std.os.argv.len) : (argi += 1) {
        const argsize = std.mem.indexOfSentinel(u8, 0, std.os.argv[argi]);
        const arg = std.os.argv[argi][0..argsize];

        var size_ptr: ?*usize = if (seql(arg, "threads"))
            &config.thread_count
        else if (seql(arg, "connections"))
            &config.connections
        else if (seql(arg, "port"))
            &config.port
        else if (seql(arg, "uring-depth"))
            &config.queue_depth
        else if (seql(arg, "recv-buffer-size"))
            &config.recv_buffer_size
        else if (seql(arg, "send-buffer-size"))
            &config.send_buffer_size
        else if (seql(arg, "db-type"))
            &config.dbtype
        else if (seql(arg, "payload"))
            &config.payload
        else
            null;

        if (size_ptr) |ptr| {
            argi += 1;
            if (argi >= std.os.argv.len) {
                size_ptr = null;
            } else {
                const numargsize = std.mem.indexOfSentinel(u8, 0, std.os.argv[argi]);
                const numarg = std.os.argv[argi][0..numargsize];

                if (std.fmt.parseInt(usize, numarg, 10)) |num| {
                    ptr.* = num;
                } else |_| {
                    size_ptr = null;
                }
            }
        }

        if (size_ptr == null) {
            return;
        }
    }

    const load_seconds: usize = 20;
    var threads: [64]std.Thread = undefined; // who cares
    var recv: []u32 = std.heap.page_allocator.alloc(u32, 64 * 1_000_000) catch unreachable;
    @memset(recv, 0);
    var status = std.atomic.Atomic(u32).init(0);
    for (0..config.thread_count) |thread_num| {
        std.debug.print("Spawning thread nr. {}\n", .{thread_num});
        threads[thread_num] = std.Thread.spawn(.{}, worker, .{ thread_num, config, &status, recv[thread_num * 1_000_000 .. (thread_num + 1) * 1_000_000] }) catch |err| {
            std.debug.print("Failed to spawn thread: {s}\n", .{@errorName(err)});
            std.os.exit(1);
        };
    }

    std.time.sleep(2 * std.time.ns_per_s);
    _ = status.fetchAdd(1, std.atomic.Ordering.Monotonic);
    std.debug.print("Starting measuring...\n", .{});
    std.time.sleep(load_seconds * std.time.ns_per_s);
    _ = status.fetchAdd(1, std.atomic.Ordering.Monotonic);
    std.debug.print("Collecting data...\n", .{});
    for (0..config.thread_count) |thread_num| {
        threads[thread_num].join();
    }
    var latency: [999_999]u32 = [_]u32{0} ** 999_999;
    var latency_sum: usize = 0;
    var reqs: usize = 0;
    for (0..config.thread_count) |thread_num| {
        for (0..999_999) |i| {
            latency[i] += recv[thread_num * 1_000_000 + i];
            latency_sum += @intCast(recv[thread_num * 1_000_000 + i]);
        }
        reqs += recv[thread_num * 1_000_000 + 999_999];
    }

    std.io.getStdIn().writer().print("Req/Sec: {}\n", .{reqs / load_seconds}) catch unreachable;

    var freqs: f64 = @floatFromInt(reqs);
    var prints: [8]f64 = [8]f64{ freqs * 0.5, freqs * 0.80, freqs * 0.90, freqs * 0.99, freqs * 0.999, freqs * 0.9999, freqs * 0.99995, freqs * 0.99999 };
    var texts: [8][]const u8 = [_][]const u8{
        "p50",
        "p80",
        "p90",
        "p99",
        "p99.9",
        "p99.99",
        "p99.995",
        "p99.999",
    };
    var count: usize = 0;
    var ripidx: usize = 0;
    for (0..8) |i| {
        while (@as(f64, @floatFromInt(count)) < prints[i]) {
            count += latency[ripidx];
            ripidx += 1;
        }
        std.io.getStdIn().writer().print("{s}: {}\n", .{ texts[i], ripidx }) catch unreachable;
    }
}
