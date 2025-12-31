//! Render Pass Definitions
//!
//! Defines render passes, their attachments, and resource bindings.
//! Each pass describes what it reads, writes, and how it should be executed.

const std = @import("std");
const resource = @import("resource.zig");
const ResourceHandle = resource.ResourceHandle;

/// Pass type enumeration
pub const PassType = enum(u8) {
    graphics, // Standard rasterization pass
    compute, // Compute shader pass
    transfer, // Copy/blit operations
};

/// Attachment load operation - what to do with attachment contents at pass start
pub const LoadOp = enum(u8) {
    load, // Preserve existing contents
    clear, // Clear to specified value
    dont_care, // Contents undefined (for write-only)

    /// Convert to Vulkan VkAttachmentLoadOp
    pub fn toVulkan(self: LoadOp) u32 {
        return switch (self) {
            .load => 0, // VK_ATTACHMENT_LOAD_OP_LOAD
            .clear => 1, // VK_ATTACHMENT_LOAD_OP_CLEAR
            .dont_care => 2, // VK_ATTACHMENT_LOAD_OP_DONT_CARE
        };
    }

    /// Convert to Metal MTLLoadAction
    pub fn toMetal(self: LoadOp) u64 {
        return switch (self) {
            .load => 2, // MTLLoadActionLoad
            .clear => 1, // MTLLoadActionClear
            .dont_care => 0, // MTLLoadActionDontCare
        };
    }
};

/// Attachment store operation - what to do with attachment contents at pass end
pub const StoreOp = enum(u8) {
    store, // Preserve contents for later use
    dont_care, // Contents can be discarded

    /// Convert to Vulkan VkAttachmentStoreOp
    pub fn toVulkan(self: StoreOp) u32 {
        return switch (self) {
            .store => 0, // VK_ATTACHMENT_STORE_OP_STORE
            .dont_care => 1, // VK_ATTACHMENT_STORE_OP_DONT_CARE
        };
    }

    /// Convert to Metal MTLStoreAction
    pub fn toMetal(self: StoreOp) u64 {
        return switch (self) {
            .store => 1, // MTLStoreActionStore
            .dont_care => 0, // MTLStoreActionDontCare
        };
    }
};

/// Color attachment configuration
pub const ColorAttachment = struct {
    resource: ResourceHandle,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
};

/// Depth/stencil attachment configuration
pub const DepthAttachment = struct {
    resource: ResourceHandle,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .dont_care,
    stencil_load_op: LoadOp = .dont_care,
    stencil_store_op: StoreOp = .dont_care,
    clear_depth: f32 = 1.0,
    clear_stencil: u8 = 0,
    read_only: bool = false, // For depth testing without writing
};

/// Shader stage flags for resource binding
pub const ShaderStageFlags = packed struct(u8) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    geometry: bool = false,
    tessellation_control: bool = false,
    tessellation_evaluation: bool = false,
    _padding: u2 = 0,

    pub const vertex_only = ShaderStageFlags{ .vertex = true };
    pub const fragment_only = ShaderStageFlags{ .fragment = true };
    pub const vertex_fragment = ShaderStageFlags{ .vertex = true, .fragment = true };
    pub const compute_only = ShaderStageFlags{ .compute = true };
    pub const all_graphics = ShaderStageFlags{ .vertex = true, .fragment = true, .geometry = true };

    /// Convert to Vulkan VkShaderStageFlags
    pub fn toVulkan(self: ShaderStageFlags) u32 {
        var flags: u32 = 0;
        if (self.vertex) flags |= 0x00000001; // VK_SHADER_STAGE_VERTEX_BIT
        if (self.fragment) flags |= 0x00000010; // VK_SHADER_STAGE_FRAGMENT_BIT
        if (self.compute) flags |= 0x00000020; // VK_SHADER_STAGE_COMPUTE_BIT
        if (self.geometry) flags |= 0x00000008; // VK_SHADER_STAGE_GEOMETRY_BIT
        if (self.tessellation_control) flags |= 0x00000002; // VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT
        if (self.tessellation_evaluation) flags |= 0x00000004; // VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT
        return flags;
    }
};

/// Resource read binding - describes a resource being sampled/read by the pass
pub const ResourceRead = struct {
    resource: ResourceHandle,
    binding: u8, // Descriptor binding index
    set: u8 = 0, // Descriptor set index
    shader_stages: ShaderStageFlags,
};

/// Resource write binding - describes a resource being written (storage image/buffer)
pub const ResourceWrite = struct {
    resource: ResourceHandle,
    binding: u8,
    set: u8 = 0,
    shader_stages: ShaderStageFlags,
};

/// Maximum attachments and bindings per pass
pub const MAX_COLOR_ATTACHMENTS: usize = 8;
pub const MAX_RESOURCE_READS: usize = 16;
pub const MAX_RESOURCE_WRITES: usize = 8;
pub const MAX_PASS_NAME_LENGTH: usize = 64;

/// Forward declaration for RenderPassContext
pub const RenderPassContext = @import("executor.zig").RenderPassContext;

/// Render pass definition
pub const RenderPass = struct {
    /// Pass name (for debugging and lookup)
    name: [MAX_PASS_NAME_LENGTH]u8 = [_]u8{0} ** MAX_PASS_NAME_LENGTH,

    /// Type of pass (graphics, compute, transfer)
    pass_type: PassType = .graphics,

    /// Color attachments (outputs)
    color_attachments: [MAX_COLOR_ATTACHMENTS]?ColorAttachment = [_]?ColorAttachment{null} ** MAX_COLOR_ATTACHMENTS,
    color_attachment_count: u8 = 0,

    /// Depth/stencil attachment
    depth_attachment: ?DepthAttachment = null,

    /// Resources read by this pass (textures sampled, buffers read)
    resource_reads: [MAX_RESOURCE_READS]?ResourceRead = [_]?ResourceRead{null} ** MAX_RESOURCE_READS,
    resource_read_count: u8 = 0,

    /// Resources written by this pass (storage images/buffers, for compute)
    resource_writes: [MAX_RESOURCE_WRITES]?ResourceWrite = [_]?ResourceWrite{null} ** MAX_RESOURCE_WRITES,
    resource_write_count: u8 = 0,

    /// Execution callback - called during graph execution
    execute_fn: ?*const fn (*RenderPassContext) void = null,

    /// User data pointer passed to execute callback
    user_data: ?*anyopaque = null,

    /// Execution order (filled during compilation)
    execution_order: u16 = 0,

    /// Whether this pass was culled (no outputs used)
    is_culled: bool = false,

    /// Get the pass name as a slice
    pub fn getName(self: *const RenderPass) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    /// Set the pass name
    pub fn setName(self: *RenderPass, name_str: []const u8) void {
        const copy_len = @min(name_str.len, MAX_PASS_NAME_LENGTH - 1);
        @memcpy(self.name[0..copy_len], name_str[0..copy_len]);
        self.name[copy_len] = 0;
    }

    /// Add a color attachment
    pub fn addColorAttachment(self: *RenderPass, attachment: ColorAttachment) bool {
        if (self.color_attachment_count >= MAX_COLOR_ATTACHMENTS) {
            return false;
        }
        self.color_attachments[self.color_attachment_count] = attachment;
        self.color_attachment_count += 1;
        return true;
    }

    /// Add a resource read
    pub fn addResourceRead(self: *RenderPass, read: ResourceRead) bool {
        if (self.resource_read_count >= MAX_RESOURCE_READS) {
            return false;
        }
        self.resource_reads[self.resource_read_count] = read;
        self.resource_read_count += 1;
        return true;
    }

    /// Add a resource write
    pub fn addResourceWrite(self: *RenderPass, write: ResourceWrite) bool {
        if (self.resource_write_count >= MAX_RESOURCE_WRITES) {
            return false;
        }
        self.resource_writes[self.resource_write_count] = write;
        self.resource_write_count += 1;
        return true;
    }

    /// Check if this pass writes to a given resource
    pub fn writesResource(self: *const RenderPass, handle: ResourceHandle) bool {
        // Check color attachments
        for (self.color_attachments[0..self.color_attachment_count]) |maybe_att| {
            if (maybe_att) |att| {
                if (att.resource.eql(handle)) {
                    return true;
                }
            }
        }

        // Check depth attachment (if not read-only)
        if (self.depth_attachment) |depth| {
            if (!depth.read_only and depth.resource.eql(handle)) {
                return true;
            }
        }

        // Check storage writes
        for (self.resource_writes[0..self.resource_write_count]) |maybe_write| {
            if (maybe_write) |write| {
                if (write.resource.eql(handle)) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Check if this pass reads a given resource
    pub fn readsResource(self: *const RenderPass, handle: ResourceHandle) bool {
        // Check texture reads
        for (self.resource_reads[0..self.resource_read_count]) |maybe_read| {
            if (maybe_read) |read| {
                if (read.resource.eql(handle)) {
                    return true;
                }
            }
        }

        // Check depth attachment if read-only
        if (self.depth_attachment) |depth| {
            if (depth.read_only and depth.resource.eql(handle)) {
                return true;
            }
        }

        return false;
    }

    /// Get all resources this pass depends on (reads from)
    pub fn getDependencies(self: *const RenderPass, out_handles: []ResourceHandle) usize {
        var count: usize = 0;

        // Add all read resources
        for (self.resource_reads[0..self.resource_read_count]) |maybe_read| {
            if (maybe_read) |read| {
                if (count < out_handles.len) {
                    out_handles[count] = read.resource;
                    count += 1;
                }
            }
        }

        // Add read-only depth
        if (self.depth_attachment) |depth| {
            if (depth.read_only and count < out_handles.len) {
                out_handles[count] = depth.resource;
                count += 1;
            }
        }

        return count;
    }

    /// Get all resources this pass produces (writes to)
    pub fn getOutputs(self: *const RenderPass, out_handles: []ResourceHandle) usize {
        var count: usize = 0;

        // Add color attachments
        for (self.color_attachments[0..self.color_attachment_count]) |maybe_att| {
            if (maybe_att) |att| {
                if (count < out_handles.len) {
                    out_handles[count] = att.resource;
                    count += 1;
                }
            }
        }

        // Add depth attachment (if not read-only)
        if (self.depth_attachment) |depth| {
            if (!depth.read_only and count < out_handles.len) {
                out_handles[count] = depth.resource;
                count += 1;
            }
        }

        // Add storage writes
        for (self.resource_writes[0..self.resource_write_count]) |maybe_write| {
            if (maybe_write) |write| {
                if (count < out_handles.len) {
                    out_handles[count] = write.resource;
                    count += 1;
                }
            }
        }

        return count;
    }
};

test "RenderPass name handling" {
    var pass = RenderPass{};
    pass.setName("shadow_pass");
    try std.testing.expectEqualStrings("shadow_pass", pass.getName());
}

test "RenderPass attachments" {
    var pass = RenderPass{};
    const handle = ResourceHandle{ .index = 0, .generation = 1 };

    try std.testing.expect(pass.addColorAttachment(.{
        .resource = handle,
        .load_op = .clear,
        .store_op = .store,
    }));

    try std.testing.expectEqual(@as(u8, 1), pass.color_attachment_count);
    try std.testing.expect(pass.writesResource(handle));
}
