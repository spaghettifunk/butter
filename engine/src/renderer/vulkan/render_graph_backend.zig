//! Vulkan Render Graph Backend
//!
//! Provides Vulkan-specific implementation for render graph execution,
//! including render pass creation, resource management, and barrier insertion.

const std = @import("std");
const vk_context = @import("context.zig");
const vk = vk_context.vk;
const renderpass = @import("renderpass.zig");
const image = @import("image.zig");
const logger = @import("../../core/logging.zig");

const render_graph = @import("../render_graph/mod.zig");
const ResourceHandle = render_graph.ResourceHandle;
const ResourceEntry = render_graph.ResourceEntry;
const TextureFormat = render_graph.TextureFormat;
const TextureDesc = render_graph.TextureDesc;
const RenderPass = render_graph.RenderPass;
const CompiledPass = render_graph.CompiledPass;
const ResourceBarrier = render_graph.ResourceBarrier;
const ImageLayout = render_graph.ImageLayout;
const AccessFlags = render_graph.AccessFlags;

/// Maximum cached render passes
pub const MAX_CACHED_RENDER_PASSES: usize = 64;

/// Render pass cache key
pub const RenderPassCacheKey = struct {
    color_formats: [8]u32,
    color_count: u8,
    depth_format: u32,
    has_depth: bool,
    color_load_ops: [8]u8,
    depth_load_op: u8,
    color_store_ops: [8]u8,
    depth_store_op: u8,

    pub fn hash(self: RenderPassCacheKey) u64 {
        var h: u64 = 0;
        h ^= @as(u64, self.color_count) << 56;
        h ^= @as(u64, self.depth_format) << 24;
        h ^= @as(u64, @intFromBool(self.has_depth)) << 16;
        h ^= @as(u64, self.depth_load_op) << 8;
        h ^= @as(u64, self.depth_store_op);

        for (0..self.color_count) |i| {
            h ^= @as(u64, self.color_formats[i]) << @intCast((i * 4) % 32);
            h ^= @as(u64, self.color_load_ops[i]) << @intCast((i * 2) % 16);
        }

        return h;
    }
};

/// Cached render pass entry
pub const CachedRenderPass = struct {
    key: RenderPassCacheKey,
    handle: vk.VkRenderPass,
    is_valid: bool = false,
};

/// Vulkan render graph backend
pub const VulkanRenderGraphBackend = struct {
    /// Reference to Vulkan context
    context: *vk_context.VulkanContext,

    /// Cached render passes
    render_pass_cache: [MAX_CACHED_RENDER_PASSES]CachedRenderPass =
        [_]CachedRenderPass{.{ .key = undefined, .handle = null, .is_valid = false }} ** MAX_CACHED_RENDER_PASSES,
    cache_count: usize = 0,

    /// Initialize the backend
    pub fn init(ctx: *vk_context.VulkanContext) VulkanRenderGraphBackend {
        return VulkanRenderGraphBackend{
            .context = ctx,
        };
    }

    /// Shutdown and cleanup
    pub fn deinit(self: *VulkanRenderGraphBackend) void {
        // Destroy cached render passes
        for (&self.render_pass_cache) |*entry| {
            if (entry.is_valid and entry.handle != null) {
                vk.vkDestroyRenderPass(self.context.device, entry.handle, self.context.allocator);
                entry.is_valid = false;
                entry.handle = null;
            }
        }
        self.cache_count = 0;
    }

    /// Get or create a render pass for the given configuration
    pub fn getOrCreateRenderPass(
        self: *VulkanRenderGraphBackend,
        pass: *const RenderPass,
        graph_resources: []const ResourceEntry,
    ) ?vk.VkRenderPass {
        // Build cache key
        var key = RenderPassCacheKey{
            .color_formats = [_]u32{0} ** 8,
            .color_count = pass.color_attachment_count,
            .depth_format = 0,
            .has_depth = pass.depth_attachment != null,
            .color_load_ops = [_]u8{0} ** 8,
            .depth_load_op = 0,
            .color_store_ops = [_]u8{0} ** 8,
            .depth_store_op = 0,
        };

        // Fill in color attachment info
        for (0..pass.color_attachment_count) |i| {
            if (pass.color_attachments[i]) |att| {
                if (att.resource.isValid() and att.resource.index < graph_resources.len) {
                    const res = &graph_resources[att.resource.index];
                    if (res.desc.getTextureDesc()) |tex_desc| {
                        key.color_formats[i] = tex_desc.format.toVulkan();
                    }
                }
                key.color_load_ops[i] = @intFromEnum(att.load_op);
                key.color_store_ops[i] = @intFromEnum(att.store_op);
            }
        }

        // Fill in depth attachment info
        if (pass.depth_attachment) |depth| {
            if (depth.resource.isValid() and depth.resource.index < graph_resources.len) {
                const res = &graph_resources[depth.resource.index];
                if (res.desc.getTextureDesc()) |tex_desc| {
                    key.depth_format = tex_desc.format.toVulkan();
                }
            }
            key.depth_load_op = @intFromEnum(depth.load_op);
            key.depth_store_op = @intFromEnum(depth.store_op);
        }

        // Check cache
        const key_hash = key.hash();
        for (&self.render_pass_cache) |*entry| {
            if (entry.is_valid and entry.key.hash() == key_hash) {
                return entry.handle;
            }
        }

        // Not in cache, create new render pass
        const new_handle = self.createRenderPass(&key) orelse return null;

        // Add to cache
        if (self.cache_count < MAX_CACHED_RENDER_PASSES) {
            self.render_pass_cache[self.cache_count] = .{
                .key = key,
                .handle = new_handle,
                .is_valid = true,
            };
            self.cache_count += 1;
        }

        return new_handle;
    }

    /// Create a new Vulkan render pass
    fn createRenderPass(self: *VulkanRenderGraphBackend, key: *const RenderPassCacheKey) ?vk.VkRenderPass {
        var attachments: [9]vk.VkAttachmentDescription = undefined;
        var attachment_count: u32 = 0;

        var color_refs: [8]vk.VkAttachmentReference = undefined;

        // Color attachments
        for (0..key.color_count) |i| {
            attachments[attachment_count] = .{
                .flags = 0,
                .format = @intCast(key.color_formats[i]),
                .samples = vk.VK_SAMPLE_COUNT_1_BIT,
                .loadOp = @intCast(key.color_load_ops[i]),
                .storeOp = @intCast(key.color_store_ops[i]),
                .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                .finalLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            };

            color_refs[i] = .{
                .attachment = attachment_count,
                .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            };

            attachment_count += 1;
        }

        // Depth attachment
        var depth_ref: vk.VkAttachmentReference = undefined;
        var has_depth_ref = false;

        if (key.has_depth and key.depth_format != 0) {
            attachments[attachment_count] = .{
                .flags = 0,
                .format = @intCast(key.depth_format),
                .samples = vk.VK_SAMPLE_COUNT_1_BIT,
                .loadOp = @intCast(key.depth_load_op),
                .storeOp = @intCast(key.depth_store_op),
                .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                .finalLayout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            };

            depth_ref = .{
                .attachment = attachment_count,
                .layout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            };
            has_depth_ref = true;

            attachment_count += 1;
        }

        // Subpass
        var subpass: vk.VkSubpassDescription = .{
            .flags = 0,
            .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = key.color_count,
            .pColorAttachments = if (key.color_count > 0) &color_refs else null,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = if (has_depth_ref) &depth_ref else null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };

        // Subpass dependency
        var dependency: vk.VkSubpassDependency = .{
            .srcSubpass = vk.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            .dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
                vk.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };

        // Create render pass
        var create_info: vk.VkRenderPassCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = attachment_count,
            .pAttachments = &attachments,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };

        var handle: vk.VkRenderPass = null;
        const result = vk.vkCreateRenderPass(
            self.context.device,
            &create_info,
            self.context.allocator,
            &handle,
        );

        if (result != vk.VK_SUCCESS) {
            logger.err("Failed to create render pass: {}", .{result});
            return null;
        }

        return handle;
    }

    /// Insert resource barriers
    pub fn insertBarriers(
        self: *VulkanRenderGraphBackend,
        command_buffer: vk.VkCommandBuffer,
        barriers: []const ResourceBarrier,
        graph_resources: []const ResourceEntry,
    ) void {
        if (barriers.len == 0) return;

        var image_barriers: [32]vk.VkImageMemoryBarrier = undefined;
        var image_barrier_count: u32 = 0;

        var src_stage: u32 = 0;
        var dst_stage: u32 = 0;

        for (barriers) |barrier| {
            if (!barrier.resource.isValid()) continue;
            if (barrier.resource.index >= graph_resources.len) continue;

            const res = &graph_resources[barrier.resource.index];

            // Determine aspect mask based on format
            var aspect_mask: u32 = vk.VK_IMAGE_ASPECT_COLOR_BIT;
            if (res.desc.getTextureDesc()) |tex_desc| {
                if (tex_desc.format.isDepthFormat()) {
                    aspect_mask = vk.VK_IMAGE_ASPECT_DEPTH_BIT;
                    if (tex_desc.format.hasStencil()) {
                        aspect_mask |= vk.VK_IMAGE_ASPECT_STENCIL_BIT;
                    }
                }
            }

            // Get image handle from backend data
            const vk_image = res.vulkan_data.image orelse continue;

            if (image_barrier_count < 32) {
                image_barriers[image_barrier_count] = .{
                    .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                    .pNext = null,
                    .srcAccessMask = barrier.src_access.toVulkan(),
                    .dstAccessMask = barrier.dst_access.toVulkan(),
                    .oldLayout = barrier.src_layout.toVulkan(),
                    .newLayout = barrier.dst_layout.toVulkan(),
                    .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
                    .image = @ptrCast(@alignCast(vk_image)),
                    .subresourceRange = .{
                        .aspectMask = aspect_mask,
                        .baseMipLevel = 0,
                        .levelCount = 1,
                        .baseArrayLayer = 0,
                        .layerCount = 1,
                    },
                };

                src_stage |= barrier.src_access.toPipelineStage();
                dst_stage |= barrier.dst_access.toPipelineStage();
                image_barrier_count += 1;
            }
        }

        if (image_barrier_count > 0) {
            // Ensure we have valid stages
            if (src_stage == 0) src_stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
            if (dst_stage == 0) dst_stage = vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;

            vk.vkCmdPipelineBarrier(
                command_buffer,
                src_stage,
                dst_stage,
                0,
                0,
                null,
                0,
                null,
                image_barrier_count,
                &image_barriers,
            );
        }
    }

    /// Create a render graph texture resource
    pub fn createTexture(
        self: *VulkanRenderGraphBackend,
        desc: *const TextureDesc,
        res_entry: *ResourceEntry,
    ) bool {
        _ = self;
        _ = desc;
        _ = res_entry;
        // TODO: Implement texture creation using VulkanImage
        // This will create VkImage, VkImageView, and optionally VkSampler
        return true;
    }

    /// Destroy a render graph texture resource
    pub fn destroyTexture(
        self: *VulkanRenderGraphBackend,
        res_entry: *ResourceEntry,
    ) void {
        _ = self;
        // TODO: Implement texture destruction
        res_entry.vulkan_data = .{};
    }
};
