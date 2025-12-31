//! Vulkan buffer management.
//!
//! Handles creation of vertex buffers, index buffers, and uniform buffers.

const std = @import("std");
const vk_context = @import("context.zig");
const vk = vk_context.vk;
const logger = @import("../../core/logging.zig");

/// Vulkan buffer with associated memory
pub const VulkanBuffer = struct {
    handle: vk.VkBuffer = null,
    memory: vk.VkDeviceMemory = null,
    size: vk.VkDeviceSize = 0,
    usage: vk.VkBufferUsageFlags = 0,
    memory_flags: vk.VkMemoryPropertyFlags = 0,
    is_locked: bool = false,
};

/// Buffer usage types for convenience
pub const BufferUsage = struct {
    pub const vertex: vk.VkBufferUsageFlags = vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    pub const index: vk.VkBufferUsageFlags = vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT | vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    pub const uniform: vk.VkBufferUsageFlags = vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    pub const staging: vk.VkBufferUsageFlags = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
};

/// Memory property flags for convenience
pub const MemoryFlags = struct {
    pub const device_local: vk.VkMemoryPropertyFlags = vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    pub const host_visible: vk.VkMemoryPropertyFlags = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
};

/// Create a Vulkan buffer with device memory
pub fn create(
    context: *vk_context.VulkanContext,
    buf: *VulkanBuffer,
    size: vk.VkDeviceSize,
    usage: vk.VkBufferUsageFlags,
    memory_flags: vk.VkMemoryPropertyFlags,
) bool {
    buf.size = size;
    buf.usage = usage;
    buf.memory_flags = memory_flags;

    // Create the buffer
    var buffer_info: vk.VkBufferCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = size,
        .usage = usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };

    var result = vk.vkCreateBuffer(context.device, &buffer_info, context.allocator, &buf.handle);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateBuffer failed with result: {}", .{result});
        return false;
    }

    // Get memory requirements
    var mem_requirements: vk.VkMemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(context.device, buf.handle, &mem_requirements);

    // Find suitable memory type
    const memory_type_index = findMemoryType(
        context,
        mem_requirements.memoryTypeBits,
        memory_flags,
    );

    if (memory_type_index == null) {
        logger.err("Failed to find suitable memory type for buffer", .{});
        vk.vkDestroyBuffer(context.device, buf.handle, context.allocator);
        buf.handle = null;
        return false;
    }

    // Allocate memory
    var alloc_info: vk.VkMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = memory_type_index.?,
    };

    result = vk.vkAllocateMemory(context.device, &alloc_info, context.allocator, &buf.memory);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkAllocateMemory failed with result: {}", .{result});
        vk.vkDestroyBuffer(context.device, buf.handle, context.allocator);
        buf.handle = null;
        return false;
    }

    // Bind memory to buffer
    result = vk.vkBindBufferMemory(context.device, buf.handle, buf.memory, 0);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkBindBufferMemory failed with result: {}", .{result});
        vk.vkFreeMemory(context.device, buf.memory, context.allocator);
        vk.vkDestroyBuffer(context.device, buf.handle, context.allocator);
        buf.memory = null;
        buf.handle = null;
        return false;
    }

    return true;
}

/// Destroy a buffer and free its memory
pub fn destroy(context: *vk_context.VulkanContext, buf: *VulkanBuffer) void {
    if (context.device == null) return;

    if (buf.memory) |memory| {
        vk.vkFreeMemory(context.device, memory, context.allocator);
        buf.memory = null;
    }

    if (buf.handle) |handle| {
        vk.vkDestroyBuffer(context.device, handle, context.allocator);
        buf.handle = null;
    }

    buf.size = 0;
    buf.usage = 0;
    buf.memory_flags = 0;
    buf.is_locked = false;
}

/// Lock buffer memory for CPU access (map)
pub fn lock(
    context: *vk_context.VulkanContext,
    buf: *VulkanBuffer,
    offset: vk.VkDeviceSize,
    size: vk.VkDeviceSize,
    flags: vk.VkMemoryMapFlags,
) ?*anyopaque {
    if (buf.memory == null) return null;

    var data: ?*anyopaque = null;
    const result = vk.vkMapMemory(context.device, buf.memory, offset, size, flags, &data);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkMapMemory failed with result: {}", .{result});
        return null;
    }

    buf.is_locked = true;
    return data;
}

/// Unlock buffer memory (unmap)
pub fn unlock(context: *vk_context.VulkanContext, buf: *VulkanBuffer) void {
    if (buf.memory == null or !buf.is_locked) return;

    vk.vkUnmapMemory(context.device, buf.memory);
    buf.is_locked = false;
}

/// Load data into a buffer (for host-visible buffers)
pub fn loadData(
    context: *vk_context.VulkanContext,
    buf: *VulkanBuffer,
    offset: vk.VkDeviceSize,
    size: vk.VkDeviceSize,
    data: *const anyopaque,
) bool {
    const mapped = lock(context, buf, offset, size, 0) orelse return false;

    const dest: [*]u8 = @ptrCast(mapped);
    const src: [*]const u8 = @ptrCast(data);
    @memcpy(dest[0..@intCast(size)], src[0..@intCast(size)]);

    unlock(context, buf);
    return true;
}

/// Copy data from one buffer to another (uses transfer queue)
pub fn copyTo(
    context: *vk_context.VulkanContext,
    command_pool: vk.VkCommandPool,
    source: *VulkanBuffer,
    dest: *VulkanBuffer,
    size: vk.VkDeviceSize,
) bool {
    // Allocate a temporary command buffer
    var alloc_info: vk.VkCommandBufferAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = command_pool,
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
        vk.vkFreeCommandBuffers(context.device, command_pool, 1, &command_buffer);
        return false;
    }

    // Record copy command
    var copy_region: vk.VkBufferCopy = .{
        .srcOffset = 0,
        .dstOffset = 0,
        .size = size,
    };

    vk.vkCmdCopyBuffer(command_buffer, source.handle, dest.handle, 1, &copy_region);

    // End recording
    result = vk.vkEndCommandBuffer(command_buffer);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkEndCommandBuffer failed with result: {}", .{result});
        vk.vkFreeCommandBuffers(context.device, command_pool, 1, &command_buffer);
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

    // Use graphics queue for now (could use transfer queue if available)
    result = vk.vkQueueSubmit(context.graphics_queue, 1, &submit_info, null);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkQueueSubmit failed with result: {}", .{result});
        vk.vkFreeCommandBuffers(context.device, command_pool, 1, &command_buffer);
        return false;
    }

    // Wait for completion
    _ = vk.vkQueueWaitIdle(context.graphics_queue);

    // Free command buffer
    vk.vkFreeCommandBuffers(context.device, command_pool, 1, &command_buffer);

    return true;
}

// --- Private helper functions ---

/// Find a suitable memory type for the given requirements
fn findMemoryType(
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
