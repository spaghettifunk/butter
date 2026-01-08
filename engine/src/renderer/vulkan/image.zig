//! Vulkan image and image view management.
//!
//! Handles creation and destruction of Vulkan images, image views, and memory.

const std = @import("std");
const vk_context = @import("context.zig");
const vk = vk_context.vk;
const logger = @import("../../core/logging.zig");

/// Vulkan image with associated memory and view
pub const VulkanImage = struct {
    handle: vk.VkImage = null,
    memory: vk.VkDeviceMemory = null,
    view: vk.VkImageView = null,
    format: vk.VkFormat = vk.VK_FORMAT_UNDEFINED,
    width: u32 = 0,
    height: u32 = 0,
};

/// Create a Vulkan image with memory and view
pub fn create(
    context: *vk_context.VulkanContext,
    image: *VulkanImage,
    width: u32,
    height: u32,
    format: vk.VkFormat,
    tiling: vk.VkImageTiling,
    usage: vk.VkImageUsageFlags,
    memory_flags: vk.VkMemoryPropertyFlags,
    aspect_flags: vk.VkImageAspectFlags,
) bool {
    image.width = width;
    image.height = height;
    image.format = format;

    // Create the image
    var image_info: vk.VkImageCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = .{
            .width = width,
            .height = height,
            .depth = 1,
        },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = tiling,
        .usage = usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };

    var result = vk.vkCreateImage(context.device, &image_info, context.allocator, &image.handle);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateImage failed with result: {}", .{result});
        return false;
    }

    // Get memory requirements
    var mem_requirements: vk.VkMemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(context.device, image.handle, &mem_requirements);

    // Find suitable memory type
    const memory_type_index = findMemoryType(
        context,
        mem_requirements.memoryTypeBits,
        memory_flags,
    );

    if (memory_type_index == null) {
        logger.err("Failed to find suitable memory type for image", .{});
        vk.vkDestroyImage(context.device, image.handle, context.allocator);
        image.handle = null;
        return false;
    }

    // Allocate memory
    var alloc_info: vk.VkMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = memory_type_index.?,
    };

    result = vk.vkAllocateMemory(context.device, &alloc_info, context.allocator, &image.memory);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkAllocateMemory failed with result: {}", .{result});
        vk.vkDestroyImage(context.device, image.handle, context.allocator);
        image.handle = null;
        return false;
    }

    // Bind memory to image
    result = vk.vkBindImageMemory(context.device, image.handle, image.memory, 0);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkBindImageMemory failed with result: {}", .{result});
        vk.vkFreeMemory(context.device, image.memory, context.allocator);
        vk.vkDestroyImage(context.device, image.handle, context.allocator);
        image.memory = null;
        image.handle = null;
        return false;
    }

    // Create image view
    image.view = createImageView(context, image.handle, format, aspect_flags, vk.VK_IMAGE_VIEW_TYPE_2D, 1);
    if (image.view == null) {
        logger.err("Failed to create image view", .{});
        vk.vkFreeMemory(context.device, image.memory, context.allocator);
        vk.vkDestroyImage(context.device, image.handle, context.allocator);
        image.memory = null;
        image.handle = null;
        return false;
    }

    return true;
}

/// Destroy a Vulkan image and free associated resources
pub fn destroy(context: *vk_context.VulkanContext, image: *VulkanImage) void {
    if (context.device == null) return;

    if (image.view) |view| {
        vk.vkDestroyImageView(context.device, view, context.allocator);
        image.view = null;
    }

    if (image.memory) |memory| {
        vk.vkFreeMemory(context.device, memory, context.allocator);
        image.memory = null;
    }

    if (image.handle) |handle| {
        vk.vkDestroyImage(context.device, handle, context.allocator);
        image.handle = null;
    }

    image.format = vk.VK_FORMAT_UNDEFINED;
    image.width = 0;
    image.height = 0;
}

/// Create an image view for an existing image
pub fn createImageView(
    context: *vk_context.VulkanContext,
    image: vk.VkImage,
    format: vk.VkFormat,
    aspect_flags: vk.VkImageAspectFlags,
    view_type: vk.VkImageViewType,
    layer_count: u32,
) vk.VkImageView {
    var view_info: vk.VkImageViewCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = view_type,
        .format = format,
        .components = .{
            .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask = aspect_flags,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = layer_count,
        },
    };

    var view: vk.VkImageView = null;
    const result = vk.vkCreateImageView(context.device, &view_info, context.allocator, &view);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateImageView failed with result: {}", .{result});
        return null;
    }

    return view;
}

/// Transition an image from one layout to another
pub fn transitionLayout(
    context: *vk_context.VulkanContext,
    command_buffer: vk.VkCommandBuffer,
    image: vk.VkImage,
    format: vk.VkFormat,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    layer_count: u32,
) void {
    _ = format; // May be used for format-specific transitions in the future

    var barrier: vk.VkImageMemoryBarrier = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = 0,
        .dstAccessMask = 0,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = layer_count,
        },
    };

    var source_stage: vk.VkPipelineStageFlags = 0;
    var destination_stage: vk.VkPipelineStageFlags = 0;

    // Determine access masks and pipeline stages based on layouts
    if (old_layout == vk.VK_IMAGE_LAYOUT_UNDEFINED and
        new_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
    {
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
        source_stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        destination_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
    } else if (old_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and
        new_layout == vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    {
        barrier.srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT;
        source_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
        destination_stage = vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    } else if (old_layout == vk.VK_IMAGE_LAYOUT_UNDEFINED and
        new_layout == vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
    {
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = vk.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
            vk.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        barrier.subresourceRange.aspectMask = vk.VK_IMAGE_ASPECT_DEPTH_BIT;
        source_stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        destination_stage = vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
    } else if (old_layout == vk.VK_IMAGE_LAYOUT_UNDEFINED and
        new_layout == vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    {
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT |
            vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        source_stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        destination_stage = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    } else if (old_layout == vk.VK_IMAGE_LAYOUT_UNDEFINED and
        new_layout == vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    {
        // Transition depth image directly to shader read optimal
        // Used for shadow maps that are never written to via renderpass
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT;
        barrier.subresourceRange.aspectMask = vk.VK_IMAGE_ASPECT_DEPTH_BIT;
        source_stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        destination_stage = vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    } else {
        logger.warn("Unsupported layout transition: {} -> {}", .{ old_layout, new_layout });
        return;
    }

    vk.vkCmdPipelineBarrier(
        command_buffer,
        source_stage,
        destination_stage,
        0, // dependency flags
        0, // memory barrier count
        null, // memory barriers
        0, // buffer memory barrier count
        null, // buffer memory barriers
        1, // image memory barrier count
        &barrier,
    );

    _ = context; // Used in other functions, kept for API consistency
}

/// Copy data from a buffer to an image
pub fn copyBufferToImage(
    command_buffer: vk.VkCommandBuffer,
    buffer: vk.VkBuffer,
    image: vk.VkImage,
    width: u32,
    height: u32,
) void {
    var region: vk.VkBufferImageCopy = .{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{
            .width = width,
            .height = height,
            .depth = 1,
        },
    };

    vk.vkCmdCopyBufferToImage(
        command_buffer,
        buffer,
        image,
        vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &region,
    );
}

/// Create a cubemap image with 6 faces
pub fn createCubemap(
    context: *vk_context.VulkanContext,
    width: u32,
    height: u32,
    format: vk.VkFormat,
    usage: vk.VkImageUsageFlags,
    image: *VulkanImage,
) bool {
    // Image creation info for cubemap
    var image_info: vk.VkImageCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT, // CRITICAL: cubemap flag
        .imageType = vk.VK_IMAGE_TYPE_2D, // 2D, not 3D!
        .format = format,
        .extent = .{
            .width = width,
            .height = height,
            .depth = 1,
        },
        .mipLevels = 1, // No mipmaps for now
        .arrayLayers = 6, // 6 faces
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };

    // Create image
    var result = vk.vkCreateImage(context.device, &image_info, context.allocator, &image.handle);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateImage failed for cubemap: {}", .{result});
        return false;
    }

    // Allocate memory (same as regular image)
    var mem_requirements: vk.VkMemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(context.device, image.handle, &mem_requirements);

    const memory_type = findMemoryType(
        context,
        mem_requirements.memoryTypeBits,
        vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    ) orelse {
        logger.err("Failed to find suitable memory type for cubemap", .{});
        vk.vkDestroyImage(context.device, image.handle, context.allocator);
        return false;
    };

    var alloc_info: vk.VkMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = memory_type,
    };

    result = vk.vkAllocateMemory(context.device, &alloc_info, context.allocator, &image.memory);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkAllocateMemory failed for cubemap: {}", .{result});
        vk.vkDestroyImage(context.device, image.handle, context.allocator);
        return false;
    }

    result = vk.vkBindImageMemory(context.device, image.handle, image.memory, 0);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkBindImageMemory failed for cubemap: {}", .{result});
        vk.vkFreeMemory(context.device, image.memory, context.allocator);
        vk.vkDestroyImage(context.device, image.handle, context.allocator);
        return false;
    }

    // Create cubemap view (6 layers)
    image.view = createImageView(
        context,
        image.handle,
        format,
        vk.VK_IMAGE_ASPECT_COLOR_BIT,
        vk.VK_IMAGE_VIEW_TYPE_CUBE, // Cubemap view type
        6, // All 6 faces
    );

    if (image.view == null) {
        logger.err("Failed to create cubemap image view", .{});
        vk.vkFreeMemory(context.device, image.memory, context.allocator);
        vk.vkDestroyImage(context.device, image.handle, context.allocator);
        return false;
    }

    image.format = format;
    image.width = width;
    image.height = height;

    return true;
}

// --- Private helper functions ---

/// Find a suitable memory type for the given requirements
pub fn findMemoryType(
    context: *vk_context.VulkanContext,
    type_filter: u32,
    properties: vk.VkMemoryPropertyFlags,
) ?u32 {
    const mem_properties = &context.physical_device_memory_properties;

    for (0..mem_properties.memoryTypeCount) |i| {
        const idx: u5 = @intCast(i);
        const type_bit: u32 = @as(u32, 1) << idx;

        if ((type_filter & type_bit) != 0) {
            if ((mem_properties.memoryTypes[i].propertyFlags & properties) == properties) {
                return @intCast(i);
            }
        }
    }

    return null;
}
