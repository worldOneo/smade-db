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

const Page = struct {
    const Block = struct {
        next: *allowzero @This(),
    };
    // Cacheline 1
    thread_id: usize,
    used: usize,
    free_list: *allowzero Block,
    bump_idx: usize,
    next_page: *allowzero Page,
    _block1: CachelineBlocker(24), // prevent false sharing

    // Cacheline 2
    thread_free: std.atomic.Atomic(*allowzero Block),
    thread_freed: std.atomic.Atomic(usize),
    _block2: CachelineBlocker(48), // prevent false sharing

    data: [pageSizeInBlocks]Block,

    const This = @This();

    pub fn clear(this: *This) void {
        this.* = .{
            .thread_id = 0,
            .used = 0,
            .free_list = @ptrFromInt(0),
            .bump_idx = 0,
            .next_page = @ptrFromInt(0),
            ._block1 = CachelineBlocker(24).init(),
            .thread_free = std.atomic.Atomic(*allowzero Block).init(@ptrFromInt(0)),
            .thread_freed = std.atomic.Atomic(usize).init(0),
            ._block2 = CachelineBlocker(48).init(),
            .data = [_]Block{.{ .next = @ptrFromInt(0) }} ** pageSizeInBlocks,
        };
    }

    // blocks must be the same for all allocations
    pub fn allocate(this: *This, comptime T: type, size: usize) ?*T {
        this.used += 1;
        std.debug.print("Allocating {}\n", .{size});
        if (@intFromPtr(this.free_list) != 0) {
            std.debug.print("From cache\n", .{});
            const alloc = this.free_list;
            this.free_list = this.free_list.next;
            return @ptrCast(alloc);
        }
        if (this.bump_idx < pageSizeInBlocks) {
            std.debug.print("From bump\n", .{});
            var alloc = @as(*T, @ptrFromInt(@intFromPtr(&this.data) + this.bump_idx));
            this.bump_idx += size;
            if (this.bump_idx <= pageSizeInBlocks) {
                return @ptrCast(alloc);
            }
        }
        const thread_reclaim = this.reclaimThreadFree();
        if (@intFromPtr(thread_reclaim) != 0) {
            std.debug.print("From threadlist\n", .{});
            const alloc = thread_reclaim;
            this.free_list = alloc.next;
            return @ptrCast(alloc);
        }
        this.used -= 1;
        return null;
    }

    pub fn free(this: *This, ptr: *void) bool {
        var block: *Block = @ptrCast(ptr);
        if (@as(usize, std.Thread.getCurrentId()) == this.thread_id) {
            block.next = this.free_list;
            this.free_list = this.next;
            this.used -= 1;
            return this.isPageUnused();
        }
        block.next = this.thread_free.load(std.atomic.Ordering.Monotonic);
        while (this.thread_free.tryCompareAndSwap(block.next, block, std.atomic.Ordering.Release, std.atomic.Ordering.Monotonic)) {
            block.next = this.thread_free.load(std.atomic.Ordering.Monotonic);
        }
        _ = this.thread_freed.fetchAdd(1, std.atomic.Ordering.Monotonic);
        return false;
    }

    fn reclaimThreadFree(this: *This) *allowzero Block {
        return this.thread_free.swap(@ptrFromInt(0), std.atomic.Ordering.Acquire);
    }

    fn isPageUnused(this: *This) bool {
        return this.used - this.thread_freed.load(std.atomic.Ordering.Monotonic) == 0;
    }
};

const sizeClasses = 64;

fn msbOnly(const_size: usize) usize {
    var size = const_size;
    size |= (size >> 1);
    size |= (size >> 2);
    size |= (size >> 4);
    size |= (size >> 8);
    size |= (size >> 16);
    size |= (size >> 32);
    return (size & ~(size >> 1));
}

fn blockCount(size: usize) usize {
    var baseClass = msbOnly(size);
    const stepSize = baseClass / 4;
    const steps = ((size - baseClass) + stepSize - 1) / stepSize;
    return baseClass + steps * stepSize;
}

const LocalAllocator = struct {};

const GAllocator = struct {
    pages: []Page,
    const This = @This();

    pub fn init(pages: u64, backing_allocator: std.mem.Allocator) std.mem.Allocator.Error!This {
        std.debug.print("Starting {}\n", .{@sizeOf(Page)});
        var heap_pages: []Page = try backing_allocator.alignedAlloc(Page, 64, pages);
        for (0..pages) |i| {
            heap_pages[i].clear();
        }
        std.debug.print("alloced\n", .{});
        return This{ .pages = heap_pages };
        // return This{ .pages = heap_pages };
    }
};

test "GAllocator" {
    std.debug.print("Lul\n", .{});
    var alloc = try GAllocator.init(10, std.heap.page_allocator);
    var page = &alloc.pages[0];
    _ = page.allocate([17]u8, blockCount(@sizeOf([17]u8)));

    std.debug.print("Ok\n", .{});
}
