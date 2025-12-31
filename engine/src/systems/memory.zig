const std = @import("std");
const logger = @import("../core/logging.zig");
const context = @import("../context.zig");

pub const AllocTag = enum {
    unknown,
    array,
    darray,
    dict,
    ring_queue,
    bst,
    string,
    application,
    job,
    texture,
    mat_inst,
    renderer,
    game,
    transform,
    entity,
    entity_node,
    scene,
    geometry,

    pub const count = @typeInfo(AllocTag).@"enum".fields.len;
};

pub const memory_tag_strings = [_][]const u8{
    "UNKNOWN     ",
    "ARRAY       ",
    "DARRAY      ",
    "DICT        ",
    "RING_QUEUE  ",
    "BST         ",
    "STRING      ",
    "APPLICATION ",
    "JOB         ",
    "TEXTURE     ",
    "MAT_INST    ",
    "RENDERER    ",
    "GAME        ",
    "TRANSFORM   ",
    "ENTITY      ",
    "ENTITY_NODE ",
    "SCENE       ",
    "GEOMETRY    ",
};

// Private instance storage (only valid in engine executable)
var instance: MemorySystem = undefined;

pub const MemorySystem = struct {
    allocator: std.mem.Allocator,
    stats: Stats,

    pub const Stats = struct {
        total_bytes: usize = 0,
        tagged_allocations: [AllocTag.count]usize = [_]usize{0} ** AllocTag.count,
    };

    /// Initialize the memory system (called by engine at startup)
    pub fn initialize() bool {
        instance = MemorySystem{
            .allocator = std.heap.page_allocator,
            .stats = .{},
        };
        // Register with the shared context
        context.get().memory = &instance;
        logger.info("Memory system initialized.", .{});
        return true;
    }

    /// Shutdown the memory system
    pub fn shutdown() void {
        context.get().memory = null;
        logger.info("Memory system shutdown.", .{});
    }
};

/// Get the memory system instance (works from engine or game)
pub fn getSystem() ?*MemorySystem {
    return context.get().memory;
}

/// Get the global allocator - this works across library boundaries
pub fn getAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

/// Generic helper to allocate and return a typed pointer
pub fn allocate(comptime T: type, tag: AllocTag) ?*T {
    const allocator = getAllocator();
    const ptr = allocator.create(T) catch return null;

    // Track allocation if memory system is initialized
    if (getSystem()) |sys| {
        sys.stats.total_bytes += @sizeOf(T);
        sys.stats.tagged_allocations[@intFromEnum(tag)] += 1;
    }

    return ptr;
}

/// Free a typed pointer
pub fn deallocate(comptime T: type, ptr: *T, tag: AllocTag) void {
    const allocator = getAllocator();

    // Track deallocation if memory system is initialized
    if (getSystem()) |sys| {
        if (sys.stats.total_bytes >= @sizeOf(T)) {
            sys.stats.total_bytes -= @sizeOf(T);
        }
        if (sys.stats.tagged_allocations[@intFromEnum(tag)] > 0) {
            sys.stats.tagged_allocations[@intFromEnum(tag)] -= 1;
        }
    }

    allocator.destroy(ptr);
}

pub fn usageString() []const u8 {
    // Static buffer that lives for the entire program lifetime
    const static = struct {
        var buf: [8000]u8 = undefined;
    };

    if (getSystem()) |sys| {
        var offset: usize = 0;

        // Header
        const header = std.fmt.bufPrint(static.buf[offset..], "Memory Usage Report\n", .{}) catch return "buffer too small";
        offset += header.len;

        const total = std.fmt.bufPrint(static.buf[offset..], "Total bytes: {}\n\n", .{sys.stats.total_bytes}) catch return "buffer too small";
        offset += total.len;

        const tag_header = std.fmt.bufPrint(static.buf[offset..], "Allocations by tag:\n", .{}) catch return "buffer too small";
        offset += tag_header.len;

        // Print each tag with allocations
        for (sys.stats.tagged_allocations, 0..) |count, i| {
            if (count > 0) {
                const line = std.fmt.bufPrint(static.buf[offset..], "  {s}: {}\n", .{ memory_tag_strings[i], count }) catch return static.buf[0..offset];
                offset += line.len;
            }
        }

        return static.buf[0..offset];
    }
    return "memory system not initialized";
}
