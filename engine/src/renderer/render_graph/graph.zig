//! Render Graph
//!
//! The main render graph structure that owns passes and resources.
//! Provides the building API for creating render graphs declaratively.

const std = @import("std");
const resource = @import("resource.zig");
const pass = @import("pass.zig");

const ResourceHandle = resource.ResourceHandle;
const ResourceDesc = resource.ResourceDesc;
const ResourceType = resource.ResourceType;
const TextureDesc = resource.TextureDesc;
const RenderPass = pass.RenderPass;
const PassType = pass.PassType;

/// Maximum passes and resources in a graph
pub const MAX_PASSES: usize = 64;
pub const MAX_RESOURCES: usize = 256;
pub const MAX_RESOURCE_NAME_LENGTH: usize = 64;

/// Backend-specific resource data (Vulkan)
pub const VulkanResourceData = struct {
    image: ?*anyopaque = null,
    image_view: ?*anyopaque = null,
    sampler: ?*anyopaque = null,
    buffer: ?*anyopaque = null,
    memory: ?*anyopaque = null,
};

/// Backend-specific resource data (Metal)
pub const MetalResourceData = struct {
    texture: ?*anyopaque = null,
    buffer: ?*anyopaque = null,
};

/// Resource entry in the graph
pub const ResourceEntry = struct {
    /// Resource descriptor (type, size, format, etc.)
    desc: ResourceDesc,

    /// Resource name for debugging and lookup
    name: [MAX_RESOURCE_NAME_LENGTH]u8 = [_]u8{0} ** MAX_RESOURCE_NAME_LENGTH,

    /// Generation counter for handle validation
    generation: u16 = 0,

    /// Whether this is an external/imported resource (e.g., swapchain image)
    is_imported: bool = false,

    /// Whether this resource must survive past graph execution
    is_exported: bool = false,

    /// First pass that uses this resource (filled during compilation)
    first_use_pass: u16 = 0xFFFF,

    /// Last pass that uses this resource (filled during compilation)
    last_use_pass: u16 = 0,

    /// Whether this entry is valid/in-use
    is_valid: bool = false,

    /// Backend-specific resource data
    vulkan_data: VulkanResourceData = .{},
    metal_data: MetalResourceData = .{},

    /// Get the resource name as a slice
    pub fn getName(self: *const ResourceEntry) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    /// Set the resource name
    pub fn setName(self: *ResourceEntry, name_str: []const u8) void {
        const copy_len = @min(name_str.len, MAX_RESOURCE_NAME_LENGTH - 1);
        @memcpy(self.name[0..copy_len], name_str[0..copy_len]);
        self.name[copy_len] = 0;
    }
};

/// The main render graph structure
pub const RenderGraph = struct {
    /// All passes in the graph
    passes: [MAX_PASSES]RenderPass = [_]RenderPass{.{}} ** MAX_PASSES,
    pass_count: u16 = 0,

    /// All resources in the graph
    resources: [MAX_RESOURCES]ResourceEntry = undefined,
    resource_count: u16 = 0,

    /// Generation counters for resource handles
    resource_generations: [MAX_RESOURCES]u16 = [_]u16{0} ** MAX_RESOURCES,

    /// Resource name to handle lookup
    resource_name_lookup: std.StringHashMap(ResourceHandle),

    /// Whether the graph has been compiled
    is_compiled: bool = false,

    /// Backbuffer resource handle (swapchain image)
    backbuffer_handle: ResourceHandle = ResourceHandle.invalid,

    /// Current frame index
    current_frame: u32 = 0,

    /// Allocator for dynamic allocations
    allocator: std.mem.Allocator,

    /// Initialize a new render graph
    pub fn init(allocator: std.mem.Allocator) RenderGraph {
        var graph = RenderGraph{
            .resource_name_lookup = std.StringHashMap(ResourceHandle).init(allocator),
            .allocator = allocator,
        };

        // Initialize all resource entries
        for (&graph.resources) |*res| {
            res.* = ResourceEntry{
                .desc = .{ .texture_2d = .{
                    .width = 0,
                    .height = 0,
                    .format = .rgba8_unorm,
                    .usage = .{},
                } },
            };
        }

        return graph;
    }

    /// Deinitialize the render graph
    pub fn deinit(self: *RenderGraph) void {
        self.resource_name_lookup.deinit();
        self.* = undefined;
    }

    // ========== Resource Creation API ==========

    /// Create a new resource in the graph
    pub fn createResource(self: *RenderGraph, name: []const u8, desc: ResourceDesc) ResourceHandle {
        if (self.resource_count >= MAX_RESOURCES) {
            return ResourceHandle.invalid;
        }

        const index = self.resource_count;
        self.resource_count += 1;

        // Increment generation for this slot
        self.resource_generations[index] +%= 1;

        const handle = ResourceHandle{
            .index = @intCast(index),
            .generation = self.resource_generations[index],
        };

        // Initialize the resource entry
        var entry = &self.resources[index];
        entry.* = ResourceEntry{
            .desc = desc,
            .generation = handle.generation,
            .is_valid = true,
        };
        entry.setName(name);

        // Add to name lookup
        const name_copy = self.allocator.dupe(u8, name) catch {
            return handle; // Still return valid handle, just won't be lookupable by name
        };
        self.resource_name_lookup.put(name_copy, handle) catch {
            self.allocator.free(name_copy);
        };

        self.is_compiled = false;
        return handle;
    }

    /// Create a 2D texture resource
    pub fn createTexture2D(
        self: *RenderGraph,
        name: []const u8,
        width: u32,
        height: u32,
        format: resource.TextureFormat,
        usage: resource.ResourceUsage,
    ) ResourceHandle {
        return self.createResource(name, .{
            .texture_2d = .{
                .width = width,
                .height = height,
                .format = format,
                .usage = usage,
            },
        });
    }

    /// Create a depth buffer resource
    pub fn createDepthBuffer(
        self: *RenderGraph,
        name: []const u8,
        width: u32,
        height: u32,
        format: resource.TextureFormat,
    ) ResourceHandle {
        return self.createResource(name, .{
            .depth_buffer = .{
                .width = width,
                .height = height,
                .format = format,
                .usage = resource.ResourceUsage.depth_target_sampled,
            },
        });
    }

    /// Import an external resource (like the swapchain backbuffer)
    pub fn importBackbuffer(self: *RenderGraph, width: u32, height: u32, format: resource.TextureFormat) ResourceHandle {
        const handle = self.createResource("backbuffer", .{
            .texture_2d = .{
                .width = width,
                .height = height,
                .format = format,
                .usage = resource.ResourceUsage.render_target,
                .is_transient = false,
            },
        });

        if (handle.isValid()) {
            self.resources[handle.index].is_imported = true;
            self.resources[handle.index].is_exported = true;
            self.backbuffer_handle = handle;
        }

        return handle;
    }

    /// Get a resource handle by name
    pub fn getResource(self: *RenderGraph, name: []const u8) ?ResourceHandle {
        return self.resource_name_lookup.get(name);
    }

    /// Get a resource entry by handle
    pub fn getResourceEntry(self: *RenderGraph, handle: ResourceHandle) ?*ResourceEntry {
        if (!handle.isValid()) return null;
        if (handle.index >= self.resource_count) return null;

        const entry = &self.resources[handle.index];
        if (!entry.is_valid) return null;
        if (entry.generation != handle.generation) return null;

        return entry;
    }

    /// Get a resource entry by handle (const version)
    pub fn getResourceEntryConst(self: *const RenderGraph, handle: ResourceHandle) ?*const ResourceEntry {
        if (!handle.isValid()) return null;
        if (handle.index >= self.resource_count) return null;

        const entry = &self.resources[handle.index];
        if (!entry.is_valid) return null;
        if (entry.generation != handle.generation) return null;

        return entry;
    }

    // ========== Pass Creation API ==========

    /// Add a new pass to the graph
    pub fn addPass(self: *RenderGraph, name: []const u8, pass_type: PassType) ?*RenderPass {
        if (self.pass_count >= MAX_PASSES) {
            return null;
        }

        const index = self.pass_count;
        self.pass_count += 1;

        var new_pass = &self.passes[index];
        new_pass.* = RenderPass{};
        new_pass.pass_type = pass_type;
        new_pass.setName(name);

        self.is_compiled = false;
        return new_pass;
    }

    /// Get a pass by name
    pub fn getPass(self: *RenderGraph, name: []const u8) ?*RenderPass {
        for (self.passes[0..self.pass_count]) |*p| {
            if (std.mem.eql(u8, p.getName(), name)) {
                return p;
            }
        }
        return null;
    }

    /// Get a pass by index
    pub fn getPassByIndex(self: *RenderGraph, index: usize) ?*RenderPass {
        if (index >= self.pass_count) return null;
        return &self.passes[index];
    }

    // ========== Graph State ==========

    /// Check if the graph needs recompilation
    pub fn needsRecompile(self: *const RenderGraph) bool {
        return !self.is_compiled;
    }

    /// Mark the graph as needing recompilation
    pub fn invalidate(self: *RenderGraph) void {
        self.is_compiled = false;
    }

    /// Reset the graph (clear all passes and resources)
    pub fn reset(self: *RenderGraph) void {
        // Clear passes
        for (&self.passes) |*p| {
            p.* = RenderPass{};
        }
        self.pass_count = 0;

        // Clear resources (but keep generations for handle safety)
        for (&self.resources) |*r| {
            r.is_valid = false;
        }
        self.resource_count = 0;

        // Clear name lookup
        var iter = self.resource_name_lookup.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.resource_name_lookup.clearRetainingCapacity();

        self.backbuffer_handle = ResourceHandle.invalid;
        self.is_compiled = false;
    }

    /// Print debug information about the graph
    pub fn debugPrint(self: *const RenderGraph, writer: anytype) !void {
        try writer.print("=== Render Graph ===\n", .{});
        try writer.print("Passes: {}\n", .{self.pass_count});
        try writer.print("Resources: {}\n", .{self.resource_count});
        try writer.print("Compiled: {}\n\n", .{self.is_compiled});

        try writer.print("--- Resources ---\n", .{});
        for (self.resources[0..self.resource_count], 0..) |res, i| {
            if (res.is_valid) {
                try writer.print("  [{}] {s}", .{ i, res.getName() });
                if (res.is_imported) try writer.print(" (imported)", .{});
                if (res.is_exported) try writer.print(" (exported)", .{});
                try writer.print("\n", .{});
            }
        }

        try writer.print("\n--- Passes ---\n", .{});
        for (self.passes[0..self.pass_count], 0..) |p, i| {
            try writer.print("  [{}] {s} ({s})", .{
                i,
                p.getName(),
                @tagName(p.pass_type),
            });
            if (p.is_culled) try writer.print(" (culled)", .{});
            try writer.print("\n", .{});

            // Print attachments
            if (p.color_attachment_count > 0) {
                try writer.print("      Color attachments: {}\n", .{p.color_attachment_count});
            }
            if (p.depth_attachment != null) {
                try writer.print("      Depth attachment: yes\n", .{});
            }
            if (p.resource_read_count > 0) {
                try writer.print("      Resource reads: {}\n", .{p.resource_read_count});
            }
        }
    }
};

test "RenderGraph resource creation" {
    var graph = RenderGraph.init(std.testing.allocator);
    defer graph.deinit();

    const handle = graph.createTexture2D(
        "test_texture",
        1920,
        1080,
        .rgba16_float,
        resource.ResourceUsage.render_target,
    );

    try std.testing.expect(handle.isValid());
    try std.testing.expectEqual(@as(u16, 1), graph.resource_count);

    const entry = graph.getResourceEntry(handle);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("test_texture", entry.?.getName());
}

test "RenderGraph pass creation" {
    var graph = RenderGraph.init(std.testing.allocator);
    defer graph.deinit();

    const shadow_pass = graph.addPass("shadow_pass", .graphics);
    try std.testing.expect(shadow_pass != null);
    try std.testing.expectEqualStrings("shadow_pass", shadow_pass.?.getName());
    try std.testing.expectEqual(@as(u16, 1), graph.pass_count);
}
