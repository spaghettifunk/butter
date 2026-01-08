//! Vulkan renderpass management.
//!
//! Handles renderpass creation, destruction, and begin/end operations.

const std = @import("std");
const vk_context = @import("context.zig");
const vk = vk_context.vk;
const logger = @import("../../core/logging.zig");

/// Renderpass state enumeration
pub const RenderpassState = enum {
    ready,
    recording,
    in_render_pass,
    recording_ended,
    submitted,
    not_allocated,
};

/// Vulkan renderpass with associated state
pub const VulkanRenderpass = struct {
    handle: vk.VkRenderPass = null,
    render_area: vk.VkRect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = 0, .height = 0 },
    },
    clear_color: vk.VkClearColorValue = .{ .float32 = .{ 0.53, 0.81, 0.92, 1.0 } }, // Light sky blue
    depth: f32 = 1.0,
    stencil: u32 = 0,
    state: RenderpassState = .not_allocated,
};

/// Create a renderpass
pub fn create(
    context: *vk_context.VulkanContext,
    renderpass: *VulkanRenderpass,
    render_area: vk.VkRect2D,
    clear_color: vk.VkClearColorValue,
    depth: f32,
    stencil: u32,
) bool {
    logger.debug("Creating renderpass...", .{});

    renderpass.render_area = render_area;
    renderpass.clear_color = clear_color;
    renderpass.depth = depth;
    renderpass.stencil = stencil;

    // Color attachment (swapchain image)
    const color_attachment: vk.VkAttachmentDescription = .{
        .flags = 0,
        .format = context.swapchain.image_format.format,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    var color_attachment_ref: vk.VkAttachmentReference = .{
        .attachment = 0,
        .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    // Depth attachment
    const depth_attachment: vk.VkAttachmentDescription = .{
        .flags = 0,
        .format = context.swapchain.depth_image.format,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    var depth_attachment_ref: vk.VkAttachmentReference = .{
        .attachment = 1,
        .layout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    // Main subpass
    var subpass: vk.VkSubpassDescription = .{
        .flags = 0,
        .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .inputAttachmentCount = 0,
        .pInputAttachments = null,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
        .pResolveAttachments = null,
        .pDepthStencilAttachment = &depth_attachment_ref,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
    };

    // Subpass dependencies for proper synchronization
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

    // Attachments array
    const attachments = [_]vk.VkAttachmentDescription{ color_attachment, depth_attachment };

    // Create renderpass
    var create_info: vk.VkRenderPassCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .attachmentCount = attachments.len,
        .pAttachments = &attachments,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    const result = vk.vkCreateRenderPass(
        context.device,
        &create_info,
        context.allocator,
        &renderpass.handle,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateRenderPass failed with result: {}", .{result});
        return false;
    }

    renderpass.state = .ready;
    logger.info("Renderpass created.", .{});
    return true;
}

/// Destroy a renderpass
pub fn destroy(context: *vk_context.VulkanContext, renderpass: *VulkanRenderpass) void {
    if (renderpass.handle) |handle| {
        logger.debug("Destroying renderpass...", .{});
        vk.vkDestroyRenderPass(context.device, handle, context.allocator);
        renderpass.handle = null;
        renderpass.state = .not_allocated;
    }
}

/// Begin a renderpass
pub fn begin(
    renderpass: *VulkanRenderpass,
    command_buffer: vk.VkCommandBuffer,
    framebuffer: vk.VkFramebuffer,
) void {
    // Set up clear values
    var clear_values: [2]vk.VkClearValue = undefined;
    clear_values[0].color = renderpass.clear_color;
    clear_values[1].depthStencil = .{
        .depth = renderpass.depth,
        .stencil = renderpass.stencil,
    };

    var begin_info: vk.VkRenderPassBeginInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext = null,
        .renderPass = renderpass.handle,
        .framebuffer = framebuffer,
        .renderArea = renderpass.render_area,
        .clearValueCount = clear_values.len,
        .pClearValues = &clear_values,
    };

    vk.vkCmdBeginRenderPass(command_buffer, &begin_info, vk.VK_SUBPASS_CONTENTS_INLINE);
    renderpass.state = .in_render_pass;
}

/// End a renderpass
pub fn end(renderpass: *VulkanRenderpass, command_buffer: vk.VkCommandBuffer) void {
    // Only end render pass if we're actually in one
    if (renderpass.state != .in_render_pass) {
        logger.warn("Attempted to end render pass when not in render pass state (current: {})", .{renderpass.state});
        return;
    }
    vk.vkCmdEndRenderPass(command_buffer);
    renderpass.state = .recording;
}

/// Create the main world renderpass (standard color + depth)
pub fn createMainRenderpass(
    context: *vk_context.VulkanContext,
    renderpass: *VulkanRenderpass,
) bool {
    const render_area = vk.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = context.swapchain.extent,
    };

    // Default clear color (light sky blue)
    const clear_color = vk.VkClearColorValue{
        .float32 = .{ 0.53, 0.81, 0.92, 1.0 },
    };

    return create(
        context,
        renderpass,
        render_area,
        clear_color,
        1.0, // depth
        0, // stencil
    );
}

/// Update renderpass render area (e.g., after resize)
pub fn updateRenderArea(renderpass: *VulkanRenderpass, width: u32, height: u32) void {
    renderpass.render_area.extent.width = width;
    renderpass.render_area.extent.height = height;
}

/// Set the clear color
pub fn setClearColor(renderpass: *VulkanRenderpass, r: f32, g: f32, b: f32, a: f32) void {
    renderpass.clear_color.float32 = .{ r, g, b, a };
}

/// Create a shadow map renderpass (depth-only rendering)
/// Used for rendering cascade shadow maps and point light shadow cubemaps
pub fn createShadowRenderpass(
    context: *vk_context.VulkanContext,
    renderpass: *VulkanRenderpass,
    width: u32,
    height: u32,
) bool {
    logger.debug("Creating shadow renderpass...", .{});

    const render_area = vk.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = width, .height = height },
    };

    renderpass.render_area = render_area;
    renderpass.depth = 1.0;
    renderpass.stencil = 0;

    // Depth attachment only (D32_SFLOAT for high precision)
    const depth_attachment: vk.VkAttachmentDescription = .{
        .flags = 0,
        .format = vk.VK_FORMAT_D32_SFLOAT,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE, // Store for sampling in main pass
        .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, // For sampling
    };

    var depth_attachment_ref: vk.VkAttachmentReference = .{
        .attachment = 0,
        .layout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    // Single subpass for depth rendering
    var subpass: vk.VkSubpassDescription = .{
        .flags = 0,
        .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .inputAttachmentCount = 0,
        .pInputAttachments = null,
        .colorAttachmentCount = 0, // No color attachments
        .pColorAttachments = null,
        .pResolveAttachments = null,
        .pDepthStencilAttachment = &depth_attachment_ref,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
    };

    // Subpass dependency for proper synchronization
    var dependency: vk.VkSubpassDependency = .{
        .srcSubpass = vk.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT |
            vk.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .dstStageMask = vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT |
            vk.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .srcAccessMask = 0,
        .dstAccessMask = vk.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dependencyFlags = 0,
    };

    // Create renderpass
    const attachments = [_]vk.VkAttachmentDescription{depth_attachment};

    var create_info: vk.VkRenderPassCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .attachmentCount = attachments.len,
        .pAttachments = &attachments,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    const result = vk.vkCreateRenderPass(
        context.device,
        &create_info,
        context.allocator,
        &renderpass.handle,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateRenderPass (shadow) failed with result: {}", .{result});
        return false;
    }

    renderpass.state = .ready;
    logger.info("Shadow renderpass created.", .{});
    return true;
}
