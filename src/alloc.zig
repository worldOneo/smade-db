const std = @import("std");

const pageSizeInBlocks = 4096;
const bytesInPage = pageSizeInBlocks * 8;

pub fn CachelineBlocker(comptime Size: u64) type {
    return struct {
        block: [Size]u8,
        pub fn init() @This() {
            return @This(){ .block = [_]u8{0} ** Size };
        }
    };
}

const PageStates = enum(usize) {
    NORMAL,
    FULL,
    REQUEUEING,
    LOCK,
};

const Block = struct {
    next: *allowzero align(1) @This(),
};

const Page = struct {
    // Cacheline 1
    thread_id: usize,
    used: usize,
    free_list: *allowzero align(1) Block,
    local_free_list: *allowzero align(1) Block,
    bump_idx: usize,
    next_page: *allowzero Page,
    prev_page: *allowzero Page,
    size_class: *allowzero SizeClass,

    // Cacheline 2
    thread_free: std.atomic.Atomic(*allowzero align(1) Block),
    thread_freed: std.atomic.Atomic(usize),
    _block2: CachelineBlocker(48), // prevent false sharing

    data: [pageSizeInBlocks]Block,

    const This = @This();

    pub fn clear(this: *This) void {
        this.* = .{
            // Cacheline 1
            .thread_id = 0,
            .used = 0,
            .free_list = @ptrFromInt(0),
            .local_free_list = @ptrFromInt(0),
            .bump_idx = 0,
            .next_page = @ptrFromInt(0),
            .prev_page = @ptrFromInt(0),
            .size_class = @ptrFromInt(0),

            // CL 2
            .thread_free = std.atomic.Atomic(*allowzero align(1) Block).init(@ptrFromInt(0)),
            .thread_freed = std.atomic.Atomic(usize).init(0),
            ._block2 = CachelineBlocker(48).init(),

            // Data
            .data = [_]Block{.{ .next = @ptrFromInt(0) }} ** pageSizeInBlocks,
        };
    }

    pub fn claimForCurrentThread(this: *This, sizeClass: *SizeClass) void {
        this.thread_id = @as(usize, @intCast(std.Thread.getCurrentId()));
        this.size_class = sizeClass;
    }

    // blocks must be the same for all allocations
    pub fn allocate(this: *This, comptime T: type, size: usize) ?*T {
        this.used += 1;
        if (@intFromPtr(this.free_list) != 0) {
            const alloc = this.local_free_list;
            this.local_free_list = this.local_free_list.next;
            return @ptrCast(alloc);
        }
        if (this.bump_idx < pageSizeInBlocks and this.bump_idx + size <= pageSizeInBlocks) {
            var alloc = @as(*T, @ptrFromInt(@intFromPtr(&this.data) + this.bump_idx));
            this.bump_idx += size;
            if (this.bump_idx <= pageSizeInBlocks) {
                return @ptrCast(alloc);
            }
        }
        // TODO: malloc generic
        this.used -= 1;
        return null;
    }

    pub fn collect(this: *This) void {
        this.free_list = this.local_free_list;
        this.local_free_list = @ptrFromInt(0);

        const thread_reclaim = this.reclaimThreadFree();
        if (@intFromPtr(thread_reclaim) != 0) {
            const head = thread_reclaim;
            var tail = head;
            var count: usize = 1;
            while (@intFromPtr(tail.next) != 0) {
                count += 1;
                tail = tail.next;
            }
            tail.next = this.free_list;
            this.free_list = head;
        }
    }

    pub fn free(this: *This, comptime T: type, ptr: *T) bool {
        var block: *align(1) Block = @ptrCast(ptr);
        if (@as(usize, std.Thread.getCurrentId()) == this.thread_id) {
            block.next = this.local_free_list;
            this.local_free_list = block;
            this.used -= 1;
            return this.isPageUnused();
        }
        block.next = this.thread_free.load(std.atomic.Ordering.Monotonic);
        while (this.thread_free.tryCompareAndSwap(block.next, block, std.atomic.Ordering.Release, std.atomic.Ordering.Monotonic)) |_| {
            block.next = this.thread_free.load(std.atomic.Ordering.Monotonic);
        }
        _ = this.thread_freed.fetchAdd(1, std.atomic.Ordering.Monotonic);
        return false;
    }

    fn reclaimThreadFree(this: *This) *allowzero align(1) Block {
        return this.thread_free.swap(@ptrFromInt(0), std.atomic.Ordering.Acquire);
    }

    fn isPageUnused(this: *This) bool {
        return this.used - this.thread_freed.load(std.atomic.Ordering.Monotonic) == 0;
    }
};

const SizeClass = struct {
    pages: *allowzero Page,
    thread_delayed: *allowzero Block,
    const This = @This();
};

const sizeClasses = 48;

fn msbOnly(const_size: usize) usize {
    const lz = @clz(const_size);
    const tz = 64 - lz - 1;
    return @as(usize, 1) << @intCast(tz);
}

fn roundToClassSize(size: usize) usize {
    var baseClass = msbOnly(size);
    const stepSize = baseClass / 4;
    const steps = ((size - baseClass) + stepSize - 1) / stepSize;
    return baseClass + steps * stepSize;
}

fn sizeClassOf(size: usize) usize {
    var baseClass = msbOnly(size);
    const stepSize = baseClass / 4;
    const steps = ((size - baseClass) + stepSize - 1) / stepSize;
    return (63 - @clz(baseClass >> 3)) * 4 + steps;
}

const LocalAllocator = struct {
    full_pages: [sizeClasses]*allowzero Page,
    class_pages: [sizeClasses]*allowzero Page,
    global_allocator: *GlobalAllocator,
    const This = @This();

    pub fn init(globalAllocator: GlobalAllocator) This {
        const a = [_]*allowzero Page{@ptrFromInt(0)} ** sizeClasses;
        return This{ .classPages = a, .glboalAllocator = globalAllocator };
    }

    pub fn allocate(this: *This, comptime T: type) ?*T {
        const size = @sizeOf(T);
        const filled_size = roundToClassSize(size);
        const class = sizeClassOf(size);
        const page = this.class_pages[class];
        if (@intFromPtr(page) != 0) {
            if (page.allocate(T, filled_size)) |allocated| {
                return allocated;
            }
        }

        return this.allocate_slow(T);
    }

    fn allocate_slow(this: *This, comptime T: type) ?*T {
        const size = @sizeOf(T);
        const filled_size = roundToClassSize(size);
        const class = sizeClassOf(size);
        var page = this.class_pages[class];

        // Collect local pages
        while (@intFromPtr(page) != 0) {
            page.collect();
            if (page.used - page.thread_freed.load(std.atomic.Ordering.Monotonic) == 0) {
                this.global_allocator.freePage(page);
            } else if (@intFromPtr(page.free_list) != 0) {
                return page.allocate(T, filled_size);
            } else {
                var next = page.next_page;
                if (@ptrFromInt(next)) {}
            }
            page = page.next_page;
        }

        if (this.global_allocator.requestFreePage()) |new_page| {
            new_page.claimForCurrentThread();
            new_page.next_page = page;
            new_page.prev_page = @ptrFromInt(0);
            if (@intFromPtr(page) != 0) {
                page.prev_page = new_page;
            }
            this.class_pages[class] = new_page;
            return new_page.allocate(T, filled_size);
        }
    }

    pub fn free(this: *This, comptime T: type, ptr: *T) void {
        const page_idx = (@intFromPtr(ptr) - @intFromPtr(this.global_allocator.pages.ptr)) / @sizeOf(Page);
        const page = this.global_allocator.pages[page_idx];
        if (page.free(T, ptr)) {
            if (@intFromPtr(page.prev_page) != 0) {
                page.prev_page.next_page = page.next_page;
            }
            if (@intFromPtr(page.next_page) != 0) {
                page.next_page.prev_page = page.prev_page;
            }
            this.global_allocator.freePage(page);
        }
    }
};

const GlobalAllocator = struct {
    pages: []Page,
    bump_idx: std.atomic.Atomic(usize),
    free_pages: std.atomic.Atomic(*allowzero Page),
    const This = @This();

    pub fn init(pages: u64, backing_allocator: std.mem.Allocator) std.mem.Allocator.Error!This {
        std.debug.print("Starting {}\n", .{@sizeOf(Page)});
        var heap_pages: []Page = try backing_allocator.alignedAlloc(Page, 64, pages);
        for (0..pages) |i| {
            heap_pages[i].clear();
        }
        std.debug.print("alloced\n", .{});
        return This{
            .pages = heap_pages,
            .bump_idx = std.atomic.Atomic(usize).init(0),
            .free_pages = std.atomic.Atomic(*allowzero Page).init(@ptrFromInt(0)),
        };
    }

    pub fn requestFreePage(this: *This) ?*Page {
        var next_page = this.free_pages.load(std.atomic.Ordering.Acquire);
        while (@intFromPtr(next_page) != 0) {
            if (this.free_pages.compareAndSwap(next_page, next_page.next_page, std.atomic.Ordering.Monotonic, std.atomic.Ordering.Monotonic) == null) {
                return next_page;
            }
            next_page = this.free_pages.load(std.atomic.Ordering.Acquire);
        }
        const claim_idx = this.bump_idx.fetchAdd(1, std.atomic.Ordering.Monotonic);
        if (claim_idx < this.pages.len) {
            return &this.pages[claim_idx];
        }
        _ = this.bump_idx.fetchSub(1, std.atomic.Ordering.Monotonic);
        return null;
    }

    pub fn freePage(this: *This, page: *Page) void {
        var next_page = this.free_pages.load(std.atomic.Ordering.Monotonic);
        page.next_page = next_page;
        while (this.free_pages.compareAndSwap(next_page, next_page.next_page, std.atomic.Ordering.Release, std.atomic.Ordering.Monotonic) != null) {
            next_page = this.free_pages.load(std.atomic.Ordering.Monotonic);
            page.next_page = next_page;
        }
    }
};

test "alloc.Page" {
    std.debug.print("Lul\n", .{});
    var alloc = try GlobalAllocator.init(10, std.heap.page_allocator);
    var page = &alloc.pages[0];
    var sizeClass = SizeClass{ .pages = @ptrFromInt(0), .thread_delayed = @ptrFromInt(0) };
    page.claimForCurrentThread(&sizeClass);
    var s1 = page.allocate([17]u8, roundToClassSize(@sizeOf([17]u8))).?;
    var s2 = page.allocate([17]u8, roundToClassSize(@sizeOf([17]u8))).?;
    var s3 = page.allocate([17]u8, roundToClassSize(@sizeOf([17]u8))).?;
    const s = "1234567890abcdefg";
    s1.* = s.*;
    s2.* = s.*;
    s3.* = s.*;
    const expect = std.testing.expect;
    try expect(std.hash_map.eqlString(s1, s));
    try expect(std.hash_map.eqlString(s2, s));
    try expect(std.hash_map.eqlString(s3, s));
    _ = page.free([17]u8, s1);
    _ = page.free([17]u8, s2);
    _ = page.free([17]u8, s3);
    _ = page.allocate([17]u8, roundToClassSize(@sizeOf([17]u8))).?;

    std.debug.print("Ok\n", .{});
}

test "alloc.sizeClass" {
    // Size classes are distributed as follows
    // 8 ,10,12,14
    // 16,20,24,28
    // 32,40,48,56
    // 64,80,96,112
    // 128...etc...
    const expectEq = std.testing.expectEqual;
    const z: usize = 0;
    try expectEq(15 + z, sizeClassOf(100));
    try expectEq(14 + z, sizeClassOf(86));
    try expectEq(13 + z, sizeClassOf(80));
    try expectEq(13 + z, sizeClassOf(70));
    try expectEq(13 + z, sizeClassOf(65));
    try expectEq(1 + z, sizeClassOf(10));
    try expectEq(1 + z, sizeClassOf(9));
    try expectEq(0 + z, sizeClassOf(8));
    try expectEq(sizeClasses + z, sizeClassOf(pageSizeInBlocks * 8));
}
