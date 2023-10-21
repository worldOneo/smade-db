const std = @import("std");
const alloc = @import("alloc.zig");
const linux = std.os.linux;

pub const Buffer = struct {
    data: []u8,
    read: usize,
    written: usize,

    const This = @This();

    pub fn init(buff: []u8) This {
        return This{
            .data = buff,
            .written = 0,
            .read = 0,
        };
    }

    pub fn push(this: *This, buff: []const u8) bool {
        if (this.available() >= buff.len) {
            @memcpy(this.data[this.written..(this.written + buff.len)], buff);
            this.written += buff.len;

            return true;
        } else {
            this.cleanup();
            if (this.available() >= buff.len) {
                @memcpy(this.data[this.written..(this.written + buff.len)], buff);

                this.written += buff.len;
                return true;
            }
        }
        return false;
    }

    pub fn dataReady(this: *This) []u8 {
        return this.data[this.read..this.written];
    }

    pub fn dataConsumed(this: *This, size: usize) void {
        this.read += size;
    }

    fn available(this: *This) usize {
        return this.data.len - this.written;
    }

    fn cleanup(this: *This) void {
        if (this.read > 0) {
            var start: usize = 0;
            for (this.read..this.written) |i| {
                this.data[start] = this.data[i];
                start += 1;
            }
            var read = this.read;
            this.read = 0;
            this.written -= read;
        }
    }

    fn freeSpace(this: *This) []u8 {
        this.cleanup();
        return this.data[this.written..this.data.len];
    }
};

pub const ContextPool = struct {
    contexts: []ConnectionContext,
    idxslab: []usize,
    idx: usize,

    const This = @This();

    pub fn createPool(contexts: usize, recvsize: usize, txsize: usize, allocator: std.mem.Allocator) !This {
        const slab = try allocator.alloc(ConnectionContext, contexts);
        const idxs = try allocator.alloc(usize, contexts);
        const buffs = try allocator.alloc(u8, contexts * (recvsize + txsize));
        for (0..contexts) |i| {
            slab[i].recvbuffer = Buffer.init(buffs[(i * (recvsize + txsize))..(i * (recvsize + txsize) + recvsize)]);
            slab[i].sendbuffer = Buffer.init(buffs[(i * (recvsize + txsize) + recvsize)..((i + 1) * (recvsize + txsize))]);
            slab[i].poolid = i;
            idxs[i] = i;
        }

        return This{
            .contexts = slab,
            .idxslab = idxs,
            .idx = contexts,
        };
    }

    fn get(this: *This) ?*ConnectionContext {
        if (this.idx > 0) {
            const ctx = &this.contexts[this.idxslab[this.idx - 1]];
            this.idx -= 1;
            return ctx;
        }
        return null;
    }

    fn returnCtx(this: *This, ctx: *ConnectionContext) void {
        this.idxslab[this.idx] = ctx.poolid;
        this.idx += 1;
    }
};

pub const IOEvent = enum {
    Connected,
    None,
    Data,
    Lost,
};

pub const IORequestType = enum(u8) {
    Accept,
    Read,
    Write,
};

const IORequest = struct {
    contextid: usize,
    requesttype: IORequestType,
    sending: u24 = 0,

    fn fromInt(i: u64) IORequest {
        return IORequest{
            .contextid = @intCast(i & ((1 << 32) - 1)),
            .sending = @intCast((i & ((1 << 56) - 1)) >> 32),
            .requesttype = @enumFromInt(i >> 56),
        };
    }

    fn toInt(this: IORequest) u64 {
        return @as(u64, @intCast(this.contextid)) |
            (@as(u64, @intFromEnum(this.requesttype)) << 56) |
            (@as(u64, @intCast(this.sending)) << 32);
    }
};

pub const ConnectionContext = struct {
    is_sending: bool,
    poolid: usize,
    userdata: *anyopaque,
    lastevent: IOEvent,
    client_addr: linux.sockaddr,
    client_fd: i32,
    recvbuffer: Buffer,
    sendbuffer: Buffer,
};

const IOServerSetupError = error{
    SocketSetup,
    SockOpReuseAddr,
    SockOpReusePort,
    SocketBind,
    MarkListen,
    IOUringSetup,
};

fn sysint(a: usize) i32 {
    const unsigned32: u32 = @intCast(a);
    const signed: i32 = @bitCast(unsigned32);
    return signed;
}

pub const IOServer = struct {
    contextpool: ContextPool,
    serverfd: i32,
    serveraddr: linux.sockaddr.in,
    uring: linux.IO_Uring,
    accepting: bool,

    const This = @This();

    pub fn init(pool: ContextPool, queue_depth: u13, port: u16) IOServerSetupError!This {
        var server: IOServer = undefined;
        server.accepting = false;

        // create TCP fd
        server.serverfd = sysint(linux.socket(linux.PF.INET, linux.SOCK.STREAM, linux.IPPROTO.TCP));
        if (server.serverfd == -1) {
            return error.SocketSetup;
        }

        // setops for TCP fd
        const enabled: i32 = 1;
        const optsaddr = sysint(linux.setsockopt(server.serverfd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&enabled), @sizeOf(i32)));
        const optsport = sysint(linux.setsockopt(server.serverfd, linux.SOL.SOCKET, linux.SO.REUSEPORT, @ptrCast(&enabled), @sizeOf(i32)));
        if (optsaddr < 0) return error.SockOpReuseAddr;
        if (optsport < 0) return error.SockOpReusePort;

        // bind addr&port to TCP fd
        server.serveraddr.family = linux.AF.INET;
        server.serveraddr.port = port;
        server.serveraddr.addr = 0;
        const sockbind = sysint(linux.bind(server.serverfd, @ptrCast(&server.serveraddr), @sizeOf(linux.sockaddr)));
        if (sockbind < 0) {
            return error.SocketBind;
        }

        const listen = sysint(linux.listen(server.serverfd, 16));
        if (listen < 0) {
            return error.MarkListen;
        }

        server.uring = linux.IO_Uring.init(queue_depth, 0) catch return error.IOUringSetup;
        server.contextpool = pool;
        return server;
    }

    fn addAcceptRequest(this: *This) !void {
        var context = this.contextpool.get() orelse return error.OutOfContexts;
        var size: u32 = @sizeOf(linux.sockaddr);
        _ = this.uring.accept(
            (IORequest{ .contextid = context.poolid, .requesttype = .Accept }).toInt(),
            this.serverfd,
            &context.client_addr,
            &size,
            0,
        ) catch |err| {
            this.contextpool.returnCtx(context);
            return err;
        };
    }

    fn addReadRequest(this: *This, ctx: *ConnectionContext) !void {
        _ = try this.uring.recv(
            (IORequest{ .contextid = ctx.poolid, .requesttype = .Read }).toInt(),
            ctx.client_fd,
            linux.IO_Uring.RecvBuffer{ .buffer = ctx.recvbuffer.freeSpace() },
            0,
        );
    }

    fn addSendRequest(this: *This, ctx: *ConnectionContext) !void {
        if (ctx.is_sending) {
            return;
        }
        ctx.is_sending = true;
        _ = this.uring.send(
            (IORequest{
                .contextid = ctx.poolid,
                .requesttype = .Write,
                .sending = @intCast(ctx.sendbuffer.dataReady().len),
            }).toInt(),
            ctx.client_fd,
            ctx.sendbuffer.dataReady(),
            0,
        ) catch |err| {
            ctx.is_sending = false;
            return err;
        };
    }

    pub fn work(this: *This, can_sleep: bool) !?*ConnectionContext {
        _ = can_sleep;
        if (!this.accepting) {
            try this.addAcceptRequest();
            _ = try this.uring.submit();
            this.accepting = true;
        }

        const ready = this.uring.cq_ready();
        if (ready == 0) return null;
        const cqe = try this.uring.copy_cqe();
        const req = IORequest.fromInt(cqe.user_data);
        const res = cqe.res;
        var ctx = &this.contextpool.contexts[req.contextid];
        switch (req.requesttype) {
            .Accept => {
                try this.addAcceptRequest();
                if (res < 0) return error.FailedToAcceptClient;
                ctx.client_fd = res;
                try this.addReadRequest(ctx);
                ctx.lastevent = .Connected;
            },
            .Read => {
                if (res >= 0) {
                    ctx.recvbuffer.written += @intCast(res);
                    try this.addReadRequest(ctx);
                    ctx.lastevent = .Data;
                } else {
                    ctx.lastevent = .Lost;
                    // TODO: Kill the client
                }
            },
            .Write => {
                ctx.is_sending = false;
                if (res > 0) {
                    ctx.sendbuffer.dataConsumed(@intCast(res));
                    if (res < req.sending) {
                        ctx.sendbuffer.cleanup(); // :(
                        try this.addSendRequest(ctx);
                    }
                } else {
                    ctx.lastevent = .Lost;
                    // TODO: Kill the client
                }
            },
        }
        return ctx;
    }

    pub fn send(this: *This, ctx: *ConnectionContext) !void {
        if (ctx.sendbuffer.dataReady().len == 0) return;
        try this.addSendRequest(ctx);
    }

    pub fn submit(this: *This) !void {
        _ = try this.uring.submit();
    }
};

test "io.Buffer" {
    const expect = std.testing.expect;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var buff = Buffer.init(try arena.allocator().alloc(u8, 16));
    try expect(buff.dataReady().len == 0);
    try expect(buff.push("1234567890"));
    try expect(std.mem.eql(u8, buff.dataReady(), "1234567890"));
    try expect(buff.push("abcdef"));
    try expect(std.mem.eql(u8, buff.dataReady(), "1234567890abcdef"));
    try expect(!buff.push("a"));
    buff.dataConsumed(16);
    try expect(buff.push("1234567890abcdef"));
    arena.deinit();
}
