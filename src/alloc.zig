const std = @import("std");

const pageSizeInBlocks = 4096;
const bytesInPage = pageSizeInBlocks * 8;

const AllocLogging = enum {
    Enabled,
    Disabled,
};

const logging: AllocLogging = .Disabled;

fn allocLog(comptime fmt: []const u8, args: anytype) void {
    if (logging == .Enabled) {
        std.debug.print(fmt, args);
    }
}

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
    QUEUEING,
};

const Block = struct {
    next: ?*align(1) @This(),
};

const Page = struct {
    const bumpMarkerFullPage: usize = 1 << 63;

    // Cacheline 1
    thread_id: usize,
    used: usize,
    free_list: ?*align(1) Block,
    local_free_list: ?*align(1) Block,
    bump_idx: usize,
    next_page: ?*Page,
    prev_page: ?*Page,
    size_class: ?*SizeClass,

    // Cacheline 2
    thread_free: std.atomic.Value(?*align(1) Block),
    _block2: CachelineBlocker(56), // prevent false sharing

    data: [pageSizeInBlocks]Block,

    const This = @This();

    pub fn clear(this: *This) void {
        this.* = .{
            // Cacheline 1
            .thread_id = 0,
            .used = 0,
            .free_list = null,
            .local_free_list = null,
            .bump_idx = 0,
            .next_page = null,
            .prev_page = null,
            .size_class = null,

            // CL 2
            .thread_free = std.atomic.Value(?*align(1) Block).init(null),
            ._block2 = CachelineBlocker(56).init(),

            // Data
            .data = [_]Block{.{ .next = null }} ** pageSizeInBlocks,
        };
    }

    pub fn claimForCurrentThread(this: *This, sizeClass: *SizeClass) void {
        this.thread_id = @as(usize, @intCast(std.Thread.getCurrentId()));
        this.size_class = sizeClass;
    }

    fn threadGuard(this: *This) void {
        if (std.Thread.getCurrentId() != this.thread_id) unreachable("Cross threading");
    }

    // blocks must be the same for all allocations
    pub fn allocate(this: *This, comptime T: type, size: usize) ?*T {
        this.threadGuard();
        this.used += 1;
        if (this.free_list) |free_list| {
            allocLog("thread {} allocating size {} ({s}) for page {*} from free list\n", .{ std.Thread.getCurrentId(), size, @typeName(T), this });
            const alloc = free_list;
            this.free_list = free_list.next;
            return @ptrCast(@alignCast(alloc));
        }
        if (this.bump_idx + size <= bytesInPage) {
            allocLog("thread {} allocating size {} ({s}) for page {*} from bump: {}\n", .{ std.Thread.getCurrentId(), size, @typeName(T), this, @intFromPtr(&this.data) + this.bump_idx });
            const alloc = @as(*T, @ptrFromInt(@intFromPtr(&this.data) + this.bump_idx));
            this.bump_idx += size;
            return @ptrCast(@alignCast(alloc));
        }

        this.used -= 1;
        var size_class: *SizeClass = this.size_class orelse unreachable;
        return size_class.allocateSlow(T, size);
    }

    pub fn collect(this: *This) void {
        this.threadGuard();
        allocLog("thread {} collecting page {*}\n", .{ std.Thread.getCurrentId(), this });

        if (this.free_list == null) {
            this.free_list = this.local_free_list;
            this.local_free_list = null;
        }

        const thread_reclaim = this.reclaimThreadFree();
        if (thread_reclaim) |reclaim| {
            const head = reclaim;
            var tail = reclaim;
            var count: usize = 1;
            while (tail.next) |next| {
                count += 1;
                tail = next;
            }
            tail.next = this.free_list;
            this.free_list = head;
            this.used -= count;
            allocLog("thread {} collecting page {*} collecting from threaded {}\n", .{ std.Thread.getCurrentId(), this, count });
        }
    }

    pub fn free(this: *This, comptime T: type, ptr: *T) bool {
        allocLog("thread {} freeing {*} in page {*} of thread {}\n", .{ std.Thread.getCurrentId(), ptr, this, this.thread_id });
        var block: *align(1) Block = @ptrCast(ptr);
        if (@as(usize, std.Thread.getCurrentId()) == this.thread_id) {
            allocLog("thread {} local free {*} in {*}\n", .{ std.Thread.getCurrentId(), ptr, this });

            // local free
            block.next = this.local_free_list;
            this.local_free_list = block;
            this.used -= 1;

            if (this.bump_idx == bumpMarkerFullPage) {
                allocLog("thread {} local marking {*} as local normal page\n", .{ std.Thread.getCurrentId(), this });
                this.bump_idx -= 1;

                if (this.thread_free.cmpxchgWeak(
                    @ptrFromInt(@intFromEnum(PageStates.FULL)),
                    @ptrFromInt(@intFromEnum(PageStates.NORMAL)),
                    .monotonic,
                    .monotonic,
                ) == null) {
                    allocLog("thread {} local marking {*} as thread normal page\n", .{ std.Thread.getCurrentId(), this });
                    // return page to available to allocate state
                    var size_class: *SizeClass = this.size_class orelse unreachable;
                    size_class.add_page(this);
                }
            }
            return this.isPageUnused();
        }

        allocLog("thread {} thread freeing in {*}\n", .{ std.Thread.getCurrentId(), this });
        while (true) {
            block.next = this.thread_free.load(.monotonic);
            // page is in full mode
            if (@intFromPtr(block.next) == @intFromEnum(PageStates.FULL)) {
                // attempt to return page to empty state & append to size class thread list
                if (this.threadReturnToSizeClass(block)) {
                    return false;
                }
            }

            // push allocation to page thread free
            if (this.thread_free.cmpxchgWeak(
                block.next,
                block,
                .release,
                .monotonic,
            ) == null) {
                break;
            }
        }
        return false;
    }

    fn reclaimThreadFree(this: *This) ?*align(1) Block {
        const value = this.thread_free.swap(null, .acquire);
        const ivalue = @intFromPtr(value);
        if (ivalue == @intFromEnum(PageStates.FULL) or ivalue == @intFromEnum(PageStates.QUEUEING)) {
            return null;
        }
        return value;
    }

    fn isPageUnused(this: *This) bool {
        return this.used == 0;
    }

    fn setNextPage(this: *This, next: ?*Page) void {
        if (next == this) unreachable("this == next");
        this.next_page = next;
    }

    fn setPrevPage(this: *This, prev: ?*Page) void {
        if (prev == this) unreachable("this == prev");
        this.prev_page = prev;
    }

    pub fn markFull(this: *This) bool {
        this.threadGuard();
        this.bump_idx = bumpMarkerFullPage;
        // mark page as full, if the page has items in the free list (thread_free != 0) it is not full anymore
        if (this.thread_free.cmpxchgStrong(
            @ptrFromInt(0),
            @ptrFromInt(@intFromEnum(PageStates.FULL)),
            .release,
            .monotonic,
        )) |_| {
            this.bump_idx -= 1;
            this.collect();
            return false;
        }
        return true;
    }

    fn threadReturnToSizeClass(this: *This, block: *align(1) Block) bool {
        // acquire queueing lock to add this page back to thread local heap
        if (this.thread_free.cmpxchgWeak(
            @ptrFromInt(@intFromEnum(PageStates.FULL)),
            @ptrFromInt(@intFromEnum(PageStates.QUEUEING)),
            .monotonic,
            .monotonic,
        )) |_| {
            // this page was already added to the thread local heap
            return false;
        }
        allocLog("thread {} defered freeing {*}\n", .{ std.Thread.getCurrentId(), this });

        // atomically push to thread_delayed stack
        while (true) {
            var size_class = this.size_class orelse unreachable;
            const head = size_class.thread_delayed.load(.monotonic);
            block.next = head;
            if (size_class.thread_delayed.cmpxchgWeak(
                head,
                block,
                .release,
                .monotonic,
            ) == null) {
                break;
            }
        }
        allocLog("thread {} thread marking normal {*}\n", .{ std.Thread.getCurrentId(), this });
        // return page to normal operation
        this.thread_free.store(@ptrFromInt(@intFromEnum(PageStates.NORMAL)), .monotonic);
        return true;
    }
};

const SizeClass = struct {
    pages: ?*Page,
    global_allocator: *GlobalAllocator,
    thread_delayed: std.atomic.Value(?*align(1) Block),
    _block1: CachelineBlocker(40),

    const This = @This();
    pub fn init(global_alloc: *GlobalAllocator) This {
        return This{
            .pages = @ptrFromInt(0),
            .thread_delayed = std.atomic.Value(?*align(1) Block).init(null),
            .global_allocator = global_alloc,
            ._block1 = CachelineBlocker(40).init(),
        };
    }

    fn add_page(this: *This, page: *Page) void {
        allocLog("thread {} adding page {} to size class {*}\n", .{ std.Thread.getCurrentId(), page, this });
        page.setNextPage(this.pages);
        page.setPrevPage(null);
        if (this.pages) |pages| {
            pages.setPrevPage(page);
        }
        this.pages = page;
    }

    pub fn allocateSized(this: *This, comptime T: type, n: usize) ?*T {
        // fastpath to claim first free item from the first page in the pool
        if (this.pages) |page| {
            if (page.allocate(T, n)) |allocated| {
                allocLog("thread {} allocating fast in size class {*}\n", .{ std.Thread.getCurrentId(), this });
                return allocated;
            }
        }
        allocLog("thread {} allocating slow in size class {*} for {} bytes.\n", .{ std.Thread.getCurrentId(), this, n });
        // slow path called on a regular base to do all the work not needded to be done in the fast path
        return this.allocateSlow(T, n);
    }

    pub fn allocate(this: *This, comptime T: type) ?*T {
        const size = @sizeOf(T);
        const filled_size = roundToClassSize(size);
        return this.allocateSized(T, filled_size);
    }

    fn allocateSlow(this: *This, comptime T: type, n: usize) ?*T {
        // reclaim previously full pages on which an async free happened
        this.deferedFrees();

        var maybe_page = this.pages;

        // Collect local pages
        while (maybe_page) |page| {
            maybe_page = page.next_page;

            page.collect();

            if (page.isPageUnused()) {
                if (page.next_page == null) {
                    return page.allocate(T, n);
                }
                allocLog("thread {} allocating slow in size class {*} freeing page {*}\n", .{ std.Thread.getCurrentId(), this, page });
                // return this page for reuse anywhere else
                this.unlinkPage(page);
                this.global_allocator.freePage(page);
            } else if (page.free_list != null) {
                allocLog("thread {} allocating slow in size class {*} fast for page {*}\n", .{ std.Thread.getCurrentId(), this, page });
                // This page can be used to allocate data
                return page.allocate(T, n);
            } else {
                allocLog("thread {} allocating slow in size class {*} marking page full {*}\n", .{ std.Thread.getCurrentId(), this, page });
                // put page in full mode for deffered reclamation
                if (!page.markFull()) {
                    return page.allocate(T, n);
                } else {
                    // unlink full page for deffered reclamation
                    this.unlinkPage(page);
                }
            }
        }

        allocLog("thread {} allocating slow in size class {*} requesting new page\n", .{ std.Thread.getCurrentId(), this });
        // No free exists anymore, requesting more allocation space for this thread.
        if (this.global_allocator.requestFreePage()) |new_page| {
            allocLog("thread {} allocating slow in size class {*} claimed new page {*}\n", .{ std.Thread.getCurrentId(), this, new_page });
            new_page.claimForCurrentThread(this);
            // prepend new page to local pool
            new_page.setNextPage(this.pages);
            new_page.setPrevPage(null);
            if (this.pages) |page| {
                page.setPrevPage(new_page);
            }
            this.pages = new_page;
            return new_page.allocate(T, n);
        }
        allocLog("thread {} allocating slow in size class {*} OOM\n", .{ std.Thread.getCurrentId(), this });

        // no free allocations exist and no free pages can be claimed
        return null;
    }

    fn unlinkPage(this: *This, page: *Page) void {
        if (page.prev_page) |prev_page| {
            prev_page.setNextPage(page.next_page);
        } else {
            this.pages = page.next_page;
        }

        if (page.next_page) |next_page| {
            next_page.setPrevPage(page.prev_page);
        }
        page.next_page = null;
        page.prev_page = null;
    }

    fn deferedFrees(this: *This) void {
        allocLog("thread {} allocating slow in size class {*} reclaiming defered frees\n", .{ std.Thread.getCurrentId(), this });
        var maybe_delayed = this.thread_delayed.swap(@ptrFromInt(0), .acquire);
        while (maybe_delayed) |delayed| {
            const next = delayed.next;
            const maybe_page = this.global_allocator.pageOfPtr(@intFromPtr(delayed));
            if (maybe_page) |page| {

                // append page to local page stack
                page.setNextPage(this.pages);
                page.setPrevPage(null);
                if (this.pages) |pages| {
                    pages.setPrevPage(page);
                }
                this.pages = page;

                // reclaim delayed marker
                delayed.next = page.local_free_list;
                page.local_free_list = delayed;
                page.used -= 1;
                allocLog("thread {} allocating slow in size class {*} reclaiming defered frees in {*} = {*}\n", .{ std.Thread.getCurrentId(), this, page, delayed });
            }
            maybe_delayed = next;
        }
    }
};

const maxSizeClass = 48;

fn msbOnly(const_size: usize) usize {
    const lz = @clz(const_size);
    const tz = 64 - lz - 1;
    return @as(usize, 1) << @intCast(tz);
}

fn roundToClassSize(size: usize) usize {
    const baseClass = msbOnly(size);
    const stepSize = baseClass / 4;
    const steps = ((size - baseClass) + stepSize - 1) / stepSize; // roundup div
    return baseClass + steps * stepSize;
}

fn sizeClassOf(size: usize) usize {
    const baseClass = msbOnly(size);
    const stepSize = baseClass / 4;
    const steps = ((size - baseClass) + stepSize - 1) / stepSize; // roundup div
    return (63 - @clz(baseClass >> 3)) * 4 + steps;
}

pub const LocalAllocator = struct {
    class_pages: [maxSizeClass + 1]SizeClass,
    global_allocator: *GlobalAllocator,
    const This = @This();

    pub fn init(global_alloc: *GlobalAllocator) This {
        const a = [_]SizeClass{SizeClass.init(global_alloc)} ** (maxSizeClass + 1);
        return This{ .class_pages = a, .global_allocator = global_alloc };
    }

    pub fn free(this: *This, comptime T: type, ptr: *T) void {
        const maybe_page = this.global_allocator.pageOfPtr(@intFromPtr(ptr));
        if (maybe_page) |page| {
            _ = page.free(T, ptr);
        }
    }

    pub fn allocate(this: *This, comptime T: type) ?*T {
        const size = @sizeOf(T);
        const class = sizeClassOf(size);
        if (class > maxSizeClass) {
            unreachable("Allocation to big for small allocator");
            return null;
        }
        return this.class_pages[class].allocate(T);
    }

    pub fn allocateSlice(this: *This, comptime T: type, n: usize) ?[]T {
        const size = roundToClassSize(@sizeOf(T) * n);
        const class = sizeClassOf(size);
        const ptr = this.class_pages[class].allocateSized(T, size) orelse return null;
        const slice: [*]T = @ptrCast(ptr);
        return slice[0..size];
    }

    pub fn freeSlice(this: *This, comptime T: type, slice: []T) void {
        this.free(T, @as(*T, @ptrCast(slice.ptr)));
    }
};

pub const GlobalAllocator = struct {
    pages: []Page,
    free_pages: std.atomic.Value(?*Page),
    const This = @This();

    pub fn init(pages: u64, backing_allocator: std.mem.Allocator) std.mem.Allocator.Error!This {
        // 64byte min allignment for known cache line allignment
        var heap_pages: []Page = try backing_allocator.alignedAlloc(Page, 64, pages);
        // null out pages
        for (0..pages) |i| {
            heap_pages[i].clear();
        }
        // internally linked list to the next page
        for (0..pages - 1) |i| {
            heap_pages[i].setNextPage(&heap_pages[i + 1]);
        }
        return This{
            .pages = heap_pages,
            .free_pages = std.atomic.Value(?*Page).init(&heap_pages[0]),
        };
    }

    pub fn pageOfPtr(this: *This, ptr_data: usize) ?*Page {
        const pages_start = @intFromPtr(this.pages.ptr);
        if (ptr_data < pages_start) {
            return null;
        }

        const idx = (ptr_data - pages_start) / @sizeOf(Page);
        if (idx > this.pages.len) {
            return null;
        }
        return &this.pages[idx];
    }

    pub fn requestFreePage(this: *This) ?*Page {
        // atomic pop from the queue
        var head = this.free_pages.load(.acquire);
        while (head) |head_page| {
            if (this.free_pages.cmpxchgStrong(
                head_page,
                head_page.next_page,
                .monotonic,
                .monotonic,
            ) == null) {
                head_page.clear();
                return head_page;
            }
            head = this.free_pages.load(.acquire);
        }
        return null;
    }

    pub fn freePage(this: *This, page: *Page) void {
        // atomic push to the queue
        var head = this.free_pages.load(.monotonic);
        page.clear();
        page.setNextPage(head);
        while (this.free_pages.cmpxchgStrong(
            head,
            page,
            .release,
            .monotonic,
        ) != null) {
            head = this.free_pages.load(.monotonic);
            page.setNextPage(head);
        }
    }
};

test "alloc.Page" {
    const OtherThreadFree = struct {
        pub fn f(ga: *GlobalAllocator, ptr: *[17]u8) void {
            var la = LocalAllocator.init(ga);
            la.free([17]u8, ptr);
        }
    };

    const expect = std.testing.expect;

    std.debug.print("\n", .{});
    var alloc = try GlobalAllocator.init(10, std.heap.page_allocator);
    var localloc = LocalAllocator.init(&alloc);

    std.debug.print(" Local alloc\n", .{});
    var s1 = localloc.allocate([17]u8).?;
    const s2 = localloc.allocate([17]u8).?;
    var s3 = localloc.allocate([17]u8).?;
    const s = "1234567890abcdefg";
    s1.* = s.*;
    s2.* = s.*;
    s3.* = s.*;
    try expect(std.hash_map.eqlString(s1, s));
    try expect(std.hash_map.eqlString(s2, s));
    try expect(std.hash_map.eqlString(s3, s));

    std.debug.print(" 2x local free\n", .{});
    _ = localloc.free([17]u8, s1);
    _ = localloc.free([17]u8, s2);

    std.debug.print(" thread free\n", .{});
    var thread = std.Thread.spawn(.{}, OtherThreadFree.f, .{ &alloc, s3 }) catch unreachable;
    thread.join();

    std.debug.print(" draining page 1\n", .{});
    for (0..(pageSizeInBlocks / roundToClassSize(17))) |_| {
        s1 = localloc.allocate([17]u8).?;
    }

    std.debug.print(" mark allocator full\n", .{});
    _ = localloc.allocate([17]u8).?;

    std.debug.print(" thread free\n", .{});
    thread = std.Thread.spawn(.{}, OtherThreadFree.f, .{ &alloc, s1 }) catch unreachable;
    thread.join();

    std.debug.print(" draining page 2\n", .{});
    for (0..(pageSizeInBlocks / roundToClassSize(17) - 1)) |_| {
        s3 = localloc.allocate([17]u8).?;
    }

    std.debug.print(" defered reclaiming\n", .{});
    _ = localloc.allocate([17]u8).?;

    std.debug.print(" mark allocator page 2 full\n", .{});
    _ = localloc.allocate([17]u8).?;

    std.debug.print(" marking normal local\n", .{});
    localloc.free([17]u8, s3);

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
    try expectEq(maxSizeClass + z, sizeClassOf(pageSizeInBlocks * 8));
}
