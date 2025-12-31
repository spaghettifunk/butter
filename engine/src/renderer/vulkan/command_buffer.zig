//! Vulkan command buffer management.
//!
//! Handles command pool creation, command buffer allocation, and recording operations.

const std = @import("std");
const vk_context = @import("context.zig");
const vk = vk_context.vk;
const logger = @import("../../core/logging.zig");
const swapchain_mod = @import("swapchain.zig");

/// Maximum number of command buffers (matches max swapchain images)
pub const MAX_COMMAND_BUFFERS: usize = swapchain_mod.MAX_SWAPCHAIN_IMAGES;

/// Command buffer state enumeration
pub const CommandBufferState = enum {
    ready,
    recording,
    in_render_pass,
    recording_ended,
    submitted,
    not_allocated,
};

/// Vulkan command buffer with associated state
pub const VulkanCommandBuffer = struct {
    handle: vk.VkCommandBuffer = null,
    state: CommandBufferState = .not_allocated,
};

/// Allocate a command buffer from a command pool
pub fn allocate(
    context: *vk_context.VulkanContext,
    command_pool: vk.VkCommandPool,
    is_primary: bool,
    command_buffer: *VulkanCommandBuffer,
) bool {
    logger.debug("Allocating command buffer...", .{});

    var alloc_info: vk.VkCommandBufferAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = command_pool,
        .level = if (is_primary) vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY else vk.VK_COMMAND_BUFFER_LEVEL_SECONDARY,
        .commandBufferCount = 1,
    };

    command_buffer.state = .not_allocated;

    const result = vk.vkAllocateCommandBuffers(
        context.device,
        &alloc_info,
        &command_buffer.handle,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkAllocateCommandBuffers failed with result: {}", .{result});
        return false;
    }

    command_buffer.state = .ready;
    logger.debug("Command buffer allocated.", .{});
    return true;
}

/// Free a command buffer back to its pool
pub fn free(
    context: *vk_context.VulkanContext,
    command_pool: vk.VkCommandPool,
    command_buffer: *VulkanCommandBuffer,
) void {
    if (command_buffer.handle == null) return;

    logger.debug("Freeing command buffer...", .{});

    vk.vkFreeCommandBuffers(
        context.device,
        command_pool,
        1,
        &command_buffer.handle,
    );

    command_buffer.handle = null;
    command_buffer.state = .not_allocated;
}

/// Begin recording commands to the command buffer
pub fn begin(
    command_buffer: *VulkanCommandBuffer,
    is_single_use: bool,
    is_renderpass_continue: bool,
    is_simultaneous_use: bool,
) bool {
    var flags: vk.VkCommandBufferUsageFlags = 0;

    if (is_single_use) {
        flags |= vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    }
    if (is_renderpass_continue) {
        flags |= vk.VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT;
    }
    if (is_simultaneous_use) {
        flags |= vk.VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT;
    }

    var begin_info: vk.VkCommandBufferBeginInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = flags,
        .pInheritanceInfo = null,
    };

    const result = vk.vkBeginCommandBuffer(command_buffer.handle, &begin_info);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkBeginCommandBuffer failed with result: {}", .{result});
        return false;
    }

    command_buffer.state = .recording;
    return true;
}

/// End recording commands to the command buffer
pub fn end(command_buffer: *VulkanCommandBuffer) bool {
    // Only end if we're actually recording
    if (command_buffer.state != .recording and command_buffer.state != .in_render_pass) {
        logger.warn("Attempted to end command buffer when not recording (current: {})", .{command_buffer.state});
        return false;
    }

    const result = vk.vkEndCommandBuffer(command_buffer.handle);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkEndCommandBuffer failed with result: {}", .{result});
        return false;
    }

    command_buffer.state = .recording_ended;
    return true;
}

/// Update the command buffer state to submitted
pub fn updateSubmitted(command_buffer: *VulkanCommandBuffer) void {
    command_buffer.state = .submitted;
}

/// Reset the command buffer to ready state
pub fn reset(command_buffer: *VulkanCommandBuffer) bool {
    const result = vk.vkResetCommandBuffer(command_buffer.handle, 0);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkResetCommandBuffer failed with result: {}", .{result});
        return false;
    }

    command_buffer.state = .ready;
    return true;
}

/// Allocate and begin a single-use command buffer for immediate submission
pub fn allocateAndBeginSingleUse(
    context: *vk_context.VulkanContext,
    command_pool: vk.VkCommandPool,
    command_buffer: *VulkanCommandBuffer,
) bool {
    if (!allocate(context, command_pool, true, command_buffer)) {
        return false;
    }

    if (!begin(command_buffer, true, false, false)) {
        free(context, command_pool, command_buffer);
        return false;
    }

    return true;
}

/// End and submit a single-use command buffer, then free it
pub fn endSingleUse(
    context: *vk_context.VulkanContext,
    command_pool: vk.VkCommandPool,
    command_buffer: *VulkanCommandBuffer,
    queue: vk.VkQueue,
) bool {
    if (!end(command_buffer)) {
        free(context, command_pool, command_buffer);
        return false;
    }

    // Submit the command buffer
    var submit_info: vk.VkSubmitInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer.handle,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    };

    var result = vk.vkQueueSubmit(queue, 1, &submit_info, null);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkQueueSubmit failed with result: {}", .{result});
        free(context, command_pool, command_buffer);
        return false;
    }

    // Wait for the queue to finish
    result = vk.vkQueueWaitIdle(queue);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkQueueWaitIdle failed with result: {}", .{result});
    }

    // Free the command buffer
    free(context, command_pool, command_buffer);
    return true;
}

// === Command Pool Functions ===

/// Create a command pool for the graphics queue family
pub fn createGraphicsCommandPool(
    context: *vk_context.VulkanContext,
    command_pool: *vk.VkCommandPool,
) bool {
    logger.debug("Creating graphics command pool...", .{});

    const graphics_family = context.queue_family_indices.graphics_family orelse {
        logger.err("Graphics queue family index not available.", .{});
        return false;
    };

    var pool_info: vk.VkCommandPoolCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = graphics_family,
    };

    const result = vk.vkCreateCommandPool(
        context.device,
        &pool_info,
        context.allocator,
        command_pool,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateCommandPool failed with result: {}", .{result});
        return false;
    }

    logger.info("Graphics command pool created.", .{});
    return true;
}

/// Destroy a command pool
pub fn destroyCommandPool(
    context: *vk_context.VulkanContext,
    command_pool: *vk.VkCommandPool,
) void {
    if (command_pool.* == null) return;
    if (context.device == null) return;

    logger.debug("Destroying command pool...", .{});

    vk.vkDestroyCommandPool(context.device, command_pool.*, context.allocator);
    command_pool.* = null;
}

// === Synchronization Object Functions ===

/// Create a semaphore
pub fn createSemaphore(
    context: *vk_context.VulkanContext,
    semaphore: *vk.VkSemaphore,
) bool {
    var semaphore_info: vk.VkSemaphoreCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };

    const result = vk.vkCreateSemaphore(
        context.device,
        &semaphore_info,
        context.allocator,
        semaphore,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateSemaphore failed with result: {}", .{result});
        return false;
    }

    return true;
}

/// Destroy a semaphore
pub fn destroySemaphore(
    context: *vk_context.VulkanContext,
    semaphore: *vk.VkSemaphore,
) void {
    if (semaphore.* == null) return;
    if (context.device == null) return;

    vk.vkDestroySemaphore(context.device, semaphore.*, context.allocator);
    semaphore.* = null;
}

/// Create a fence
pub fn createFence(
    context: *vk_context.VulkanContext,
    fence: *vk.VkFence,
    signaled: bool,
) bool {
    var fence_info: vk.VkFenceCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = null,
        .flags = if (signaled) vk.VK_FENCE_CREATE_SIGNALED_BIT else 0,
    };

    const result = vk.vkCreateFence(
        context.device,
        &fence_info,
        context.allocator,
        fence,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateFence failed with result: {}", .{result});
        return false;
    }

    return true;
}

/// Destroy a fence
pub fn destroyFence(
    context: *vk_context.VulkanContext,
    fence: *vk.VkFence,
) void {
    if (fence.* == null) return;
    if (context.device == null) return;

    vk.vkDestroyFence(context.device, fence.*, context.allocator);
    fence.* = null;
}

/// Wait for a fence to be signaled
pub fn waitForFence(
    context: *vk_context.VulkanContext,
    fence: vk.VkFence,
    timeout_ns: u64,
) bool {
    const result = vk.vkWaitForFences(
        context.device,
        1,
        &fence,
        vk.VK_TRUE,
        timeout_ns,
    );

    if (result == vk.VK_SUCCESS) {
        return true;
    } else if (result == vk.VK_TIMEOUT) {
        logger.warn("Fence wait timed out.", .{});
        return false;
    } else {
        logger.err("vkWaitForFences failed with result: {}", .{result});
        return false;
    }
}

/// Reset a fence to unsignaled state
pub fn resetFence(
    context: *vk_context.VulkanContext,
    fence: vk.VkFence,
) bool {
    const result = vk.vkResetFences(context.device, 1, &fence);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkResetFences failed with result: {}", .{result});
        return false;
    }
    return true;
}
