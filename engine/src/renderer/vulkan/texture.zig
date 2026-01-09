//! Vulkan texture management.
//!
//! Handles creation and destruction of textures for the Vulkan backend.

const std = @import("std");
const vk_context = @import("context.zig");
const vk = vk_context.vk;
const vulkan_image = @import("image.zig");
const vulkan_buffer = @import("buffer.zig");
const logger = @import("../../core/logging.zig");
const resource_types = @import("../../resources/types.zig");

/// Vulkan-specific texture data
pub const VulkanTexture = struct {
    image: vulkan_image.VulkanImage = .{},
    sampler: vk.VkSampler = null,
};

/// Texture filter mode
pub const FilterMode = enum {
    linear,
    nearest,
};

/// Create a texture from raw pixel data
pub fn create(
    context: *vk_context.VulkanContext,
    texture: *resource_types.Texture,
    width: u32,
    height: u32,
    channel_count: u8,
    has_transparency: bool,
    pixels: []const u8,
) bool {
    return createWithFilter(context, texture, width, height, channel_count, has_transparency, pixels, .linear);
}

/// Create a texture from raw pixel data with specified filter mode
pub fn createWithFilter(
    context: *vk_context.VulkanContext,
    texture: *resource_types.Texture,
    width: u32,
    height: u32,
    channel_count: u8,
    has_transparency: bool,
    pixels: []const u8,
    filter_mode: FilterMode,
) bool {
    texture.width = width;
    texture.height = height;
    texture.channel_count = channel_count;
    texture.has_transparency = has_transparency;

    // Allocate internal Vulkan texture data
    const internal_data = std.heap.page_allocator.create(VulkanTexture) catch {
        logger.err("Failed to allocate VulkanTexture internal data", .{});
        return false;
    };
    internal_data.* = .{};

    // Determine format based on channel count
    // Use SRGB format for color textures (3-4 channels) for proper color representation
    // Use UNORM for single/dual channel textures (normal maps, masks, etc.)
    const format: vk.VkFormat = switch (channel_count) {
        1 => vk.VK_FORMAT_R8_UNORM,
        2 => vk.VK_FORMAT_R8G8_UNORM,
        3 => vk.VK_FORMAT_R8G8B8_SRGB,
        4 => vk.VK_FORMAT_R8G8B8A8_SRGB,
        else => {
            logger.err("Unsupported channel count: {}", .{channel_count});
            std.heap.page_allocator.destroy(internal_data);
            return false;
        },
    };

    // Calculate image size
    const image_size: vk.VkDeviceSize = @as(vk.VkDeviceSize, width) * @as(vk.VkDeviceSize, height) * @as(vk.VkDeviceSize, channel_count);

    // Create staging buffer
    var staging_buffer: vulkan_buffer.VulkanBuffer = .{};
    if (!vulkan_buffer.create(
        context,
        &staging_buffer,
        image_size,
        vulkan_buffer.BufferUsage.staging,
        vulkan_buffer.MemoryFlags.host_visible,
    )) {
        logger.err("Failed to create staging buffer for texture", .{});
        std.heap.page_allocator.destroy(internal_data);
        return false;
    }

    // Copy pixel data to staging buffer
    if (!vulkan_buffer.loadData(context, &staging_buffer, 0, image_size, pixels.ptr)) {
        logger.err("Failed to load pixel data into staging buffer", .{});
        vulkan_buffer.destroy(context, &staging_buffer);
        std.heap.page_allocator.destroy(internal_data);
        return false;
    }

    // Create the image
    if (!vulkan_image.create(
        context,
        &internal_data.image,
        width,
        height,
        format,
        vk.VK_IMAGE_TILING_OPTIMAL,
        vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
        vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        vk.VK_IMAGE_ASPECT_COLOR_BIT,
    )) {
        logger.err("Failed to create Vulkan image for texture", .{});
        vulkan_buffer.destroy(context, &staging_buffer);
        std.heap.page_allocator.destroy(internal_data);
        return false;
    }

    // Transition image layout and copy data
    if (!copyDataToImage(context, &staging_buffer, &internal_data.image, width, height, format)) {
        logger.err("Failed to copy data to texture image", .{});
        vulkan_image.destroy(context, &internal_data.image);
        vulkan_buffer.destroy(context, &staging_buffer);
        std.heap.page_allocator.destroy(internal_data);
        return false;
    }

    // Destroy staging buffer (no longer needed)
    vulkan_buffer.destroy(context, &staging_buffer);

    // Create sampler
    if (!createSampler(context, &internal_data.sampler, filter_mode)) {
        logger.err("Failed to create texture sampler", .{});
        vulkan_image.destroy(context, &internal_data.image);
        std.heap.page_allocator.destroy(internal_data);
        return false;
    }

    texture.internal_data = internal_data;
    texture.generation += 1;

    logger.debug("Texture created: {}x{}, {} channels", .{ width, height, channel_count });
    return true;
}

/// Create a cubemap texture from 6 face images
/// Face order: +X (right), -X (left), +Y (top), -Y (bottom), +Z (front), -Z (back)
pub fn createCubemap(
    context: *vk_context.VulkanContext,
    texture: *resource_types.Texture,
    width: u32,
    height: u32,
    channel_count: u8,
    face_pixels: [6][]const u8,
) bool {
    const command_buffer_module = @import("command_buffer.zig");

    // Validate all faces are same size
    const expected_size = width * height * @as(usize, channel_count);
    for (face_pixels) |face| {
        if (face.len != expected_size) {
            logger.err("Cubemap face size mismatch: expected {}, got {}", .{ expected_size, face.len });
            return false;
        }
    }

    // Select format based on channel count (same as 2D textures)
    const format: vk.VkFormat = switch (channel_count) {
        1 => vk.VK_FORMAT_R8_UNORM,
        2 => vk.VK_FORMAT_R8G8_UNORM,
        3 => vk.VK_FORMAT_R8G8B8_SRGB,
        4 => vk.VK_FORMAT_R8G8B8A8_SRGB,
        else => {
            logger.err("Unsupported channel count for cubemap: {}", .{channel_count});
            return false;
        },
    };

    // Allocate internal data
    const internal_data = std.heap.page_allocator.create(VulkanTexture) catch {
        logger.err("Failed to allocate cubemap internal data", .{});
        return false;
    };
    internal_data.* = .{};

    // Create staging buffer for all 6 faces
    const total_size = expected_size * 6;
    var staging_buffer: vulkan_buffer.VulkanBuffer = undefined;
    if (!vulkan_buffer.create(
        context,
        &staging_buffer,
        total_size,
        vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    )) {
        logger.err("Failed to create staging buffer for cubemap", .{});
        std.heap.page_allocator.destroy(internal_data);
        return false;
    }

    // Copy all 6 faces to staging buffer
    var data_ptr: ?*anyopaque = null;
    _ = vk.vkMapMemory(context.device, staging_buffer.memory, 0, total_size, 0, &data_ptr);
    if (data_ptr) |ptr| {
        const dest_slice = @as([*]u8, @ptrCast(ptr))[0..total_size];
        for (face_pixels, 0..) |face, i| {
            const offset = i * expected_size;
            @memcpy(dest_slice[offset .. offset + expected_size], face);
        }
        vk.vkUnmapMemory(context.device, staging_buffer.memory);
    } else {
        logger.err("Failed to map staging buffer memory for cubemap", .{});
        vulkan_buffer.destroy(context, &staging_buffer);
        std.heap.page_allocator.destroy(internal_data);
        return false;
    }

    // Create cubemap image
    if (!vulkan_image.createCubemap(
        context,
        width,
        height,
        format,
        vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
        &internal_data.image,
    )) {
        logger.err("Failed to create cubemap image", .{});
        vulkan_buffer.destroy(context, &staging_buffer);
        std.heap.page_allocator.destroy(internal_data);
        return false;
    }

    // Begin single-use command buffer for upload
    var cmd_buffer: command_buffer_module.VulkanCommandBuffer = undefined;
    if (!command_buffer_module.allocateAndBeginSingleUse(context, context.graphics_command_pool, &cmd_buffer)) {
        logger.err("Failed to begin command buffer for cubemap upload", .{});
        vulkan_image.destroy(context, &internal_data.image);
        vulkan_buffer.destroy(context, &staging_buffer);
        std.heap.page_allocator.destroy(internal_data);
        return false;
    }

    // Transition layout: UNDEFINED → TRANSFER_DST (all 6 layers)
    vulkan_image.transitionLayout(
        context,
        cmd_buffer.handle,
        internal_data.image.handle,
        format,
        vk.VK_IMAGE_LAYOUT_UNDEFINED,
        vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        6, // All 6 faces
    );

    // Copy staging buffer to each cubemap face
    for (0..6) |face_idx| {
        var copy_region: vk.VkBufferImageCopy = .{
            .bufferOffset = face_idx * expected_size,
            .bufferRowLength = 0, // Tightly packed
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = @intCast(face_idx),
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
            cmd_buffer.handle,
            staging_buffer.handle,
            internal_data.image.handle,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &copy_region,
        );
    }

    // Transition layout: TRANSFER_DST → SHADER_READ_ONLY (all 6 layers)
    vulkan_image.transitionLayout(
        context,
        cmd_buffer.handle,
        internal_data.image.handle,
        format,
        vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        6, // All 6 faces
    );

    // End and submit command buffer
    if (!command_buffer_module.endSingleUse(context, context.graphics_command_pool, &cmd_buffer, context.graphics_queue)) {
        logger.err("Failed to submit cubemap upload commands", .{});
        vulkan_image.destroy(context, &internal_data.image);
        vulkan_buffer.destroy(context, &staging_buffer);
        std.heap.page_allocator.destroy(internal_data);
        return false;
    }

    // Destroy staging buffer (no longer needed)
    vulkan_buffer.destroy(context, &staging_buffer);

    // Create sampler (same as 2D texture)
    if (!createSampler(context, &internal_data.sampler, .linear)) {
        logger.err("Failed to create sampler for cubemap", .{});
        vulkan_image.destroy(context, &internal_data.image);
        std.heap.page_allocator.destroy(internal_data);
        return false;
    }

    // Store in texture resource
    texture.width = width;
    texture.height = height;
    texture.channel_count = channel_count;
    texture.has_transparency = channel_count == 4;
    texture.internal_data = internal_data;
    texture.generation += 1;

    logger.info("Cubemap texture created: {}x{}, {} channels", .{ width, height, channel_count });
    return true;
}

/// Destroy a texture and free all associated resources
pub fn destroy(context: *vk_context.VulkanContext, texture: *resource_types.Texture) void {
    if (context.device == null) return;

    // Wait for device to be idle before destroying resources
    _ = vk.vkDeviceWaitIdle(context.device);

    if (texture.internal_data) |data| {
        const internal_data: *VulkanTexture = @ptrCast(@alignCast(data));

        // Destroy sampler
        if (internal_data.sampler) |sampler| {
            vk.vkDestroySampler(context.device, sampler, context.allocator);
            internal_data.sampler = null;
        }

        // Destroy image
        vulkan_image.destroy(context, &internal_data.image);

        // Free internal data
        std.heap.page_allocator.destroy(internal_data);
        texture.internal_data = null;
    }

    texture.width = 0;
    texture.height = 0;
    texture.channel_count = 0;
    texture.has_transparency = false;
    texture.generation = 0;

    logger.debug("Texture destroyed", .{});
}

// --- Private helper functions ---

/// Copy data from staging buffer to image with proper layout transitions
fn copyDataToImage(
    context: *vk_context.VulkanContext,
    staging_buffer: *vulkan_buffer.VulkanBuffer,
    image: *vulkan_image.VulkanImage,
    width: u32,
    height: u32,
    format: vk.VkFormat,
) bool {
    // Allocate a temporary command buffer
    var alloc_info: vk.VkCommandBufferAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = context.graphics_command_pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    var command_buffer: vk.VkCommandBuffer = null;
    var result = vk.vkAllocateCommandBuffers(context.device, &alloc_info, &command_buffer);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkAllocateCommandBuffers failed with result: {}", .{result});
        return false;
    }

    // Begin recording
    var begin_info: vk.VkCommandBufferBeginInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };

    result = vk.vkBeginCommandBuffer(command_buffer, &begin_info);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkBeginCommandBuffer failed with result: {}", .{result});
        vk.vkFreeCommandBuffers(context.device, context.graphics_command_pool, 1, &command_buffer);
        return false;
    }

    // Transition image layout from UNDEFINED to TRANSFER_DST_OPTIMAL
    vulkan_image.transitionLayout(
        context,
        command_buffer,
        image.handle,
        format,
        vk.VK_IMAGE_LAYOUT_UNDEFINED,
        vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
    );

    // Copy buffer to image
    vulkan_image.copyBufferToImage(
        command_buffer,
        staging_buffer.handle,
        image.handle,
        width,
        height,
    );

    // Transition image layout from TRANSFER_DST_OPTIMAL to SHADER_READ_ONLY_OPTIMAL
    vulkan_image.transitionLayout(
        context,
        command_buffer,
        image.handle,
        format,
        vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        1,
    );

    // End recording
    result = vk.vkEndCommandBuffer(command_buffer);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkEndCommandBuffer failed with result: {}", .{result});
        vk.vkFreeCommandBuffers(context.device, context.graphics_command_pool, 1, &command_buffer);
        return false;
    }

    // Submit command buffer
    var submit_info: vk.VkSubmitInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    };

    result = vk.vkQueueSubmit(context.graphics_queue, 1, &submit_info, null);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkQueueSubmit failed with result: {}", .{result});
        vk.vkFreeCommandBuffers(context.device, context.graphics_command_pool, 1, &command_buffer);
        return false;
    }

    // Wait for completion
    _ = vk.vkQueueWaitIdle(context.graphics_queue);

    // Free command buffer
    vk.vkFreeCommandBuffers(context.device, context.graphics_command_pool, 1, &command_buffer);

    return true;
}

/// Create a texture sampler
fn createSampler(context: *vk_context.VulkanContext, sampler: *vk.VkSampler, filter_mode: FilterMode) bool {
    const vk_filter: vk.VkFilter = switch (filter_mode) {
        .linear => vk.VK_FILTER_LINEAR,
        .nearest => vk.VK_FILTER_NEAREST,
    };
    const mipmap_mode: vk.VkSamplerMipmapMode = switch (filter_mode) {
        .linear => vk.VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .nearest => vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
    };
    // Disable anisotropy for nearest filtering to keep sharp pixels
    const anisotropy_enable: vk.VkBool32 = if (filter_mode == .linear) vk.VK_TRUE else vk.VK_FALSE;

    var sampler_info: vk.VkSamplerCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .magFilter = vk_filter,
        .minFilter = vk_filter,
        .mipmapMode = mipmap_mode,
        .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .mipLodBias = 0.0,
        .anisotropyEnable = anisotropy_enable,
        .maxAnisotropy = context.physical_device_properties.limits.maxSamplerAnisotropy,
        .compareEnable = vk.VK_FALSE,
        .compareOp = vk.VK_COMPARE_OP_ALWAYS,
        .minLod = 0.0,
        .maxLod = 0.0,
        .borderColor = vk.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = vk.VK_FALSE,
    };

    const result = vk.vkCreateSampler(context.device, &sampler_info, context.allocator, sampler);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateSampler failed with result: {}", .{result});
        return false;
    }

    return true;
}

/// Get internal Vulkan texture data (for descriptor updates)
pub fn getTextureData(texture: *resource_types.Texture) *VulkanTexture {
    return @ptrCast(@alignCast(texture.internal_data.?));
}
