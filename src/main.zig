const std = @import("std");
const io = @import("io.zig");

pub fn main() !void {
    var ctxpool = try io.ContextPool.createPool(100, 1024, 1024, std.heap.page_allocator);
    var ring: io.IOServer = try io.IOServer.init(ctxpool, 128, 3456);

    std.debug.print("Ring started\n", .{});

    // simple IO Uring echo server
    while (true) {
        std.time.sleep(5 * std.time.ns_per_ms);
        while (ring.work(false) catch |err| {
            std.debug.print("IO Error: {s}\n", .{@errorName(err)});
            continue;
        }) |item| {
            if (item.lastevent == .Connected) {
                std.debug.print("Accepted client on: {}\n", .{@as(*align(1) std.os.linux.sockaddr.in, @ptrCast(&item.client_addr)).port});
                continue;
            }
            var ready = item.recvbuffer.dataReady();
            if (!item.sendbuffer.push(ready)) {
                std.debug.print("Failed to push data to buff... ._.\n", .{});
                continue;
            }
            item.recvbuffer.dataConsumed(ready.len);
            ring.send(item) catch |err| {
                std.debug.print("Failed to send data = {s}", .{@errorName(err)});
            };
        }
        ring.submit() catch |err| {
            std.debug.print("Failed to submit ring = {s}", .{@errorName(err)});
        };
    }
}
