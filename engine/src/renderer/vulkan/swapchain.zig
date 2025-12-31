//! Vulkan swapchain management.
//!
//! Handles swapchain creation, image acquisition, and presentation.

const std = @import("std");
const vk_context = @import("context.zig");
const vk = vk_context.vk;
const vulkan_image = @import("image.zig");
const logger = @import("../../core/logging.zig");

/// Maximum number of swapchain images supported
pub const MAX_SWAPCHAIN_IMAGES: usize = 8;

/// Vulkan swapchain state
pub const VulkanSwapchain = struct {
    handle: vk.VkSwapchainKHR = null,
    image_format: vk.VkSurfaceFormatKHR = undefined,
    present_mode: vk.VkPresentModeKHR = undefined,
    extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },
    max_frames_in_flight: u32 = 2,

    // Swapchain images (owned by swapchain, not created by us)
    image_count: u32 = 0,
    images: [MAX_SWAPCHAIN_IMAGES]vk.VkImage = [_]vk.VkImage{null} ** MAX_SWAPCHAIN_IMAGES,

    // Image views (created by us, must be destroyed)
    image_views: [MAX_SWAPCHAIN_IMAGES]vk.VkImageView = [_]vk.VkImageView{null} ** MAX_SWAPCHAIN_IMAGES,

    // Framebuffers (one per swapchain image)
    framebuffers: [MAX_SWAPCHAIN_IMAGES]vk.VkFramebuffer = [_]vk.VkFramebuffer{null} ** MAX_SWAPCHAIN_IMAGES,

    // Depth buffer
    depth_image: vulkan_image.VulkanImage = .{},
};

/// Create the swapchain
pub fn create(
    context: *vk_context.VulkanContext,
    swapchain: *VulkanSwapchain,
    width: u32,
    height: u32,
) bool {
    logger.debug("Creating swapchain...", .{});

    // Query swapchain support (refresh in case surface changed)
    var support: vk_context.SwapchainSupportDetails = .{};
    querySwapchainSupport(context, &support);

    // Choose surface format
    const surface_format = chooseSurfaceFormat(&support);
    swapchain.image_format = surface_format;

    // Choose present mode
    const present_mode = choosePresentMode(&support);
    swapchain.present_mode = present_mode;

    // Choose swap extent
    const extent = chooseSwapExtent(&support.capabilities, width, height);
    swapchain.extent = extent;

    // Determine image count (prefer triple buffering)
    var image_count = support.capabilities.minImageCount + 1;
    if (support.capabilities.maxImageCount > 0 and image_count > support.capabilities.maxImageCount) {
        image_count = support.capabilities.maxImageCount;
    }

    // Clamp to our maximum
    if (image_count > MAX_SWAPCHAIN_IMAGES) {
        image_count = MAX_SWAPCHAIN_IMAGES;
    }

    // Determine sharing mode based on queue families
    const indices = context.queue_family_indices;
    const graphics_family = indices.graphics_family.?;
    const present_family = indices.present_family.?;

    var sharing_mode: vk.VkSharingMode = undefined;
    var queue_family_index_count: u32 = 0;
    var queue_family_indices: [2]u32 = undefined;

    if (graphics_family != present_family) {
        // Different queue families - use concurrent mode
        sharing_mode = vk.VK_SHARING_MODE_CONCURRENT;
        queue_family_index_count = 2;
        queue_family_indices[0] = graphics_family;
        queue_family_indices[1] = present_family;
        logger.debug("Using concurrent sharing mode for swapchain", .{});
    } else {
        // Same queue family - use exclusive mode (more efficient)
        sharing_mode = vk.VK_SHARING_MODE_EXCLUSIVE;
        queue_family_index_count = 0;
        logger.debug("Using exclusive sharing mode for swapchain", .{});
    }

    // Create swapchain
    var create_info: vk.VkSwapchainCreateInfoKHR = .{
        .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .pNext = null,
        .flags = 0,
        .surface = context.surface,
        .minImageCount = image_count,
        .imageFormat = surface_format.format,
        .imageColorSpace = surface_format.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = sharing_mode,
        .queueFamilyIndexCount = queue_family_index_count,
        .pQueueFamilyIndices = if (queue_family_index_count > 0) &queue_family_indices else null,
        .preTransform = support.capabilities.currentTransform,
        .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = vk.VK_TRUE,
        .oldSwapchain = null, // TODO: pass old swapchain for recreation
    };

    var result = vk.vkCreateSwapchainKHR(context.device, &create_info, context.allocator, &swapchain.handle);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateSwapchainKHR failed with result: {}", .{result});
        return false;
    }

    logger.info("Swapchain created: {}x{}, {} images", .{ extent.width, extent.height, image_count });

    // Get swapchain images
    result = vk.vkGetSwapchainImagesKHR(context.device, swapchain.handle, &swapchain.image_count, null);
    if (result != vk.VK_SUCCESS) {
        logger.err("Failed to get swapchain image count: {}", .{result});
        return false;
    }

    if (swapchain.image_count > MAX_SWAPCHAIN_IMAGES) {
        logger.warn("Swapchain has {} images, clamping to {}", .{ swapchain.image_count, MAX_SWAPCHAIN_IMAGES });
        swapchain.image_count = MAX_SWAPCHAIN_IMAGES;
    }

    result = vk.vkGetSwapchainImagesKHR(context.device, swapchain.handle, &swapchain.image_count, &swapchain.images);
    if (result != vk.VK_SUCCESS) {
        logger.err("Failed to get swapchain images: {}", .{result});
        return false;
    }

    logger.debug("Retrieved {} swapchain images", .{swapchain.image_count});

    // Create image views for swapchain images
    if (!createImageViews(context, swapchain)) {
        logger.err("Failed to create swapchain image views", .{});
        return false;
    }

    // Create depth buffer
    if (!createDepthResources(context, swapchain)) {
        logger.err("Failed to create depth resources", .{});
        return false;
    }

    logger.info("Swapchain initialization complete.", .{});
    return true;
}

/// Destroy the swapchain and associated resources
pub fn destroy(context: *vk_context.VulkanContext, swapchain: *VulkanSwapchain) void {
    if (context.device == null) return;

    logger.debug("Destroying swapchain...", .{});

    // Wait for device to be idle
    _ = vk.vkDeviceWaitIdle(context.device);

    // Destroy framebuffers
    destroyFramebuffers(context, swapchain);

    // Destroy depth resources
    vulkan_image.destroy(context, &swapchain.depth_image);

    // Destroy image views
    destroyImageViews(context, swapchain);

    // Destroy swapchain
    if (swapchain.handle) |handle| {
        vk.vkDestroySwapchainKHR(context.device, handle, context.allocator);
        swapchain.handle = null;
    }

    // Clear image handles (images are owned by swapchain, not destroyed separately)
    for (&swapchain.images) |*img| {
        img.* = null;
    }
    swapchain.image_count = 0;

    logger.debug("Swapchain destroyed.", .{});
}

/// Recreate the swapchain (e.g., after window resize)
pub fn recreate(
    context: *vk_context.VulkanContext,
    swapchain: *VulkanSwapchain,
    width: u32,
    height: u32,
) bool {
    logger.debug("Recreating swapchain...", .{});

    // Wait for device to be idle
    _ = vk.vkDeviceWaitIdle(context.device);

    // Destroy old resources
    destroy(context, swapchain);

    // Create new swapchain
    return create(context, swapchain, width, height);
}

/// Acquire the next image from the swapchain
pub fn acquireNextImage(
    context: *vk_context.VulkanContext,
    swapchain: *VulkanSwapchain,
    timeout_ns: u64,
    image_available_semaphore: vk.VkSemaphore,
    fence: vk.VkFence,
    out_image_index: *u32,
) vk.VkResult {
    return vk.vkAcquireNextImageKHR(
        context.device,
        swapchain.handle,
        timeout_ns,
        image_available_semaphore,
        fence,
        out_image_index,
    );
}

/// Present an image to the screen
pub fn present(
    context: *vk_context.VulkanContext,
    swapchain: *VulkanSwapchain,
    render_complete_semaphore: vk.VkSemaphore,
    image_index: u32,
) vk.VkResult {
    var present_info: vk.VkPresentInfoKHR = .{
        .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pNext = null,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &render_complete_semaphore,
        .swapchainCount = 1,
        .pSwapchains = &swapchain.handle,
        .pImageIndices = &image_index,
        .pResults = null,
    };

    return vk.vkQueuePresentKHR(context.present_queue, &present_info);
}

// --- Private helper functions ---

/// Query swapchain support details
fn querySwapchainSupport(context: *vk_context.VulkanContext, details: *vk_context.SwapchainSupportDetails) void {
    // Get surface capabilities
    _ = vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
        context.physical_device,
        context.surface,
        &details.capabilities,
    );

    // Get surface formats
    _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(
        context.physical_device,
        context.surface,
        &details.format_count,
        null,
    );
    if (details.format_count > 0) {
        if (details.format_count > 32) {
            details.format_count = 32;
        }
        _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(
            context.physical_device,
            context.surface,
            &details.format_count,
            &details.formats,
        );
    }

    // Get present modes
    _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(
        context.physical_device,
        context.surface,
        &details.present_mode_count,
        null,
    );
    if (details.present_mode_count > 0) {
        if (details.present_mode_count > 16) {
            details.present_mode_count = 16;
        }
        _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(
            context.physical_device,
            context.surface,
            &details.present_mode_count,
            &details.present_modes,
        );
    }
}

/// Choose the best surface format
fn chooseSurfaceFormat(support: *const vk_context.SwapchainSupportDetails) vk.VkSurfaceFormatKHR {
    // Prefer SRGB with non-linear color space for best visual quality
    for (support.formats[0..support.format_count]) |format| {
        if (format.format == vk.VK_FORMAT_B8G8R8A8_SRGB and
            format.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            logger.debug("Selected preferred surface format: B8G8R8A8_SRGB", .{});
            return format;
        }
    }

    // Fall back to B8G8R8A8_UNORM if SRGB not available
    for (support.formats[0..support.format_count]) |format| {
        if (format.format == vk.VK_FORMAT_B8G8R8A8_UNORM) {
            logger.debug("Selected fallback surface format: B8G8R8A8_UNORM", .{});
            return format;
        }
    }

    // Last resort: just use the first available format
    logger.debug("Using first available surface format", .{});
    return support.formats[0];
}

/// Choose the best present mode
fn choosePresentMode(support: *const vk_context.SwapchainSupportDetails) vk.VkPresentModeKHR {
    // Prefer mailbox (triple buffering) for low latency without tearing
    for (support.present_modes[0..support.present_mode_count]) |mode| {
        if (mode == vk.VK_PRESENT_MODE_MAILBOX_KHR) {
            logger.debug("Selected present mode: MAILBOX (triple buffering)", .{});
            return mode;
        }
    }

    // FIFO is guaranteed to be available (vsync)
    logger.debug("Selected present mode: FIFO (vsync)", .{});
    return vk.VK_PRESENT_MODE_FIFO_KHR;
}

/// Choose the swap extent (resolution)
fn chooseSwapExtent(capabilities: *const vk.VkSurfaceCapabilitiesKHR, width: u32, height: u32) vk.VkExtent2D {
    // If currentExtent is not the special value (0xFFFFFFFF), use it
    if (capabilities.currentExtent.width != 0xFFFFFFFF) {
        return capabilities.currentExtent;
    }

    // Otherwise, pick extent within allowed bounds
    var actual_extent = vk.VkExtent2D{
        .width = width,
        .height = height,
    };

    actual_extent.width = @max(
        capabilities.minImageExtent.width,
        @min(capabilities.maxImageExtent.width, actual_extent.width),
    );
    actual_extent.height = @max(
        capabilities.minImageExtent.height,
        @min(capabilities.maxImageExtent.height, actual_extent.height),
    );

    return actual_extent;
}

/// Create image views for swapchain images
fn createImageViews(context: *vk_context.VulkanContext, swapchain: *VulkanSwapchain) bool {
    logger.debug("Creating {} swapchain image views...", .{swapchain.image_count});

    for (swapchain.images[0..swapchain.image_count], 0..) |image, i| {
        const view = vulkan_image.createImageView(
            context,
            image,
            swapchain.image_format.format,
            vk.VK_IMAGE_ASPECT_COLOR_BIT,
        );

        if (view == null) {
            logger.err("Failed to create image view for swapchain image {}", .{i});
            return false;
        }

        swapchain.image_views[i] = view;
    }

    logger.debug("Swapchain image views created.", .{});
    return true;
}

/// Destroy swapchain image views
fn destroyImageViews(context: *vk_context.VulkanContext, swapchain: *VulkanSwapchain) void {
    for (&swapchain.image_views) |*view| {
        if (view.*) |v| {
            vk.vkDestroyImageView(context.device, v, context.allocator);
            view.* = null;
        }
    }
}

/// Create depth buffer resources
fn createDepthResources(context: *vk_context.VulkanContext, swapchain: *VulkanSwapchain) bool {
    logger.debug("Creating depth resources...", .{});

    // Find a suitable depth format
    const depth_format = findDepthFormat(context);
    if (depth_format == vk.VK_FORMAT_UNDEFINED) {
        logger.err("Failed to find suitable depth format", .{});
        return false;
    }

    // Create depth image
    if (!vulkan_image.create(
        context,
        &swapchain.depth_image,
        swapchain.extent.width,
        swapchain.extent.height,
        depth_format,
        vk.VK_IMAGE_TILING_OPTIMAL,
        vk.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        vk.VK_IMAGE_ASPECT_DEPTH_BIT,
    )) {
        logger.err("Failed to create depth image", .{});
        return false;
    }

    logger.debug("Depth resources created.", .{});
    return true;
}

/// Find a suitable depth format
fn findDepthFormat(context: *vk_context.VulkanContext) vk.VkFormat {
    // Preferred depth formats in order of preference
    const candidates = [_]vk.VkFormat{
        vk.VK_FORMAT_D32_SFLOAT,
        vk.VK_FORMAT_D32_SFLOAT_S8_UINT,
        vk.VK_FORMAT_D24_UNORM_S8_UINT,
    };

    for (candidates) |format| {
        var props: vk.VkFormatProperties = undefined;
        vk.vkGetPhysicalDeviceFormatProperties(context.physical_device, format, &props);

        if ((props.optimalTilingFeatures & vk.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) != 0) {
            return format;
        }
    }

    return vk.VK_FORMAT_UNDEFINED;
}

/// Create framebuffers for the swapchain (requires renderpass)
pub fn createFramebuffers(
    context: *vk_context.VulkanContext,
    swapchain_ptr: *VulkanSwapchain,
    renderpass: vk.VkRenderPass,
) bool {
    logger.debug("Creating {} framebuffers...", .{swapchain_ptr.image_count});

    for (0..swapchain_ptr.image_count) |i| {
        // Attachments: color (swapchain image view) and depth
        const attachments = [_]vk.VkImageView{
            swapchain_ptr.image_views[i],
            swapchain_ptr.depth_image.view,
        };

        var framebuffer_info: vk.VkFramebufferCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = renderpass,
            .attachmentCount = attachments.len,
            .pAttachments = &attachments,
            .width = swapchain_ptr.extent.width,
            .height = swapchain_ptr.extent.height,
            .layers = 1,
        };

        const result = vk.vkCreateFramebuffer(
            context.device,
            &framebuffer_info,
            context.allocator,
            &swapchain_ptr.framebuffers[i],
        );

        if (result != vk.VK_SUCCESS) {
            logger.err("vkCreateFramebuffer failed for framebuffer {}: {}", .{ i, result });
            return false;
        }
    }

    logger.debug("Framebuffers created.", .{});
    return true;
}

/// Destroy framebuffers
fn destroyFramebuffers(context: *vk_context.VulkanContext, swapchain_ptr: *VulkanSwapchain) void {
    for (&swapchain_ptr.framebuffers) |*fb| {
        if (fb.*) |framebuffer| {
            vk.vkDestroyFramebuffer(context.device, framebuffer, context.allocator);
            fb.* = null;
        }
    }
}
