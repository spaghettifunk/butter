//! Vulkan descriptor management.
//!
//! Handles descriptor set layouts, descriptor pools, and descriptor sets.

const std = @import("std");
const vk_context = @import("context.zig");
const vk = vk_context.vk;
const logger = @import("../../core/logging.zig");
const swapchain = @import("swapchain.zig");
const vulkan_texture = @import("texture.zig");
const resource_types = @import("../../resources/types.zig");

/// Maximum descriptor sets that can be allocated
pub const MAX_DESCRIPTOR_SETS: usize = swapchain.MAX_SWAPCHAIN_IMAGES;

/// Descriptor state for material shader
pub const MaterialShaderDescriptorState = struct {
    /// Descriptor set layout for global UBO (MVP matrices)
    global_layout: vk.VkDescriptorSetLayout = null,

    /// Descriptor pool
    pool: vk.VkDescriptorPool = null,

    /// Descriptor sets (one per frame in flight)
    global_sets: [MAX_DESCRIPTOR_SETS]vk.VkDescriptorSet =
        [_]vk.VkDescriptorSet{null} ** MAX_DESCRIPTOR_SETS,
};

/// Create the global descriptor set layout for UBO and texture sampler bindings
pub fn createGlobalLayout(
    context: *vk_context.VulkanContext,
    state: *MaterialShaderDescriptorState,
) bool {
    // Descriptor set bindings
    var layout_bindings: [2]vk.VkDescriptorSetLayoutBinding = .{
        // Global UBO binding: set 0, binding 0
        .{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Texture sampler binding: set 0, binding 1
        .{
            .binding = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
    };

    var layout_info: vk.VkDescriptorSetLayoutCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = layout_bindings.len,
        .pBindings = &layout_bindings,
    };

    const result = vk.vkCreateDescriptorSetLayout(
        context.device,
        &layout_info,
        context.allocator,
        &state.global_layout,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateDescriptorSetLayout failed with result: {}", .{result});
        return false;
    }

    logger.debug("Descriptor set layout created.", .{});
    return true;
}

/// Destroy the global descriptor set layout
pub fn destroyGlobalLayout(
    context: *vk_context.VulkanContext,
    state: *MaterialShaderDescriptorState,
) void {
    if (context.device == null) return;

    if (state.global_layout) |layout| {
        vk.vkDestroyDescriptorSetLayout(context.device, layout, context.allocator);
        state.global_layout = null;
    }
}

/// Create the descriptor pool
pub fn createPool(
    context: *vk_context.VulkanContext,
    state: *MaterialShaderDescriptorState,
    max_sets: u32,
) bool {
    // Pool sizes for uniform buffers and combined image samplers
    var pool_sizes: [2]vk.VkDescriptorPoolSize = .{
        .{
            .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = max_sets,
        },
        .{
            .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = max_sets,
        },
    };

    var pool_info: vk.VkDescriptorPoolCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = max_sets,
        .poolSizeCount = pool_sizes.len,
        .pPoolSizes = &pool_sizes,
    };

    const result = vk.vkCreateDescriptorPool(
        context.device,
        &pool_info,
        context.allocator,
        &state.pool,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateDescriptorPool failed with result: {}", .{result});
        return false;
    }

    logger.debug("Descriptor pool created.", .{});
    return true;
}

/// Destroy the descriptor pool (also frees all descriptor sets)
pub fn destroyPool(
    context: *vk_context.VulkanContext,
    state: *MaterialShaderDescriptorState,
) void {
    if (context.device == null) return;

    if (state.pool) |pool| {
        vk.vkDestroyDescriptorPool(context.device, pool, context.allocator);
        state.pool = null;
    }

    // Clear descriptor set handles (they're freed with the pool)
    for (&state.global_sets) |*set| {
        set.* = null;
    }
}

/// Allocate descriptor sets from the pool
pub fn allocateSets(
    context: *vk_context.VulkanContext,
    state: *MaterialShaderDescriptorState,
    count: u32,
) bool {
    if (state.pool == null or state.global_layout == null) {
        logger.err("Cannot allocate descriptor sets: pool or layout is null", .{});
        return false;
    }

    if (count > MAX_DESCRIPTOR_SETS) {
        logger.err("Cannot allocate {} descriptor sets (max: {})", .{ count, MAX_DESCRIPTOR_SETS });
        return false;
    }

    // Create array of layouts (same layout for each set)
    var layouts: [MAX_DESCRIPTOR_SETS]vk.VkDescriptorSetLayout = undefined;
    for (0..count) |i| {
        layouts[i] = state.global_layout;
    }

    var alloc_info: vk.VkDescriptorSetAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = state.pool,
        .descriptorSetCount = count,
        .pSetLayouts = &layouts,
    };

    const result = vk.vkAllocateDescriptorSets(
        context.device,
        &alloc_info,
        &state.global_sets,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkAllocateDescriptorSets failed with result: {}", .{result});
        return false;
    }

    logger.debug("Allocated {} descriptor sets.", .{count});
    return true;
}

/// Update a descriptor set with buffer info (UBO only)
pub fn updateGlobalSet(
    context: *vk_context.VulkanContext,
    state: *MaterialShaderDescriptorState,
    set_index: u32,
    buffer_info: *const vk.VkDescriptorBufferInfo,
) void {
    if (set_index >= MAX_DESCRIPTOR_SETS) {
        logger.err("Invalid descriptor set index: {}", .{set_index});
        return;
    }

    var write: vk.VkWriteDescriptorSet = .{
        .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,
        .dstSet = state.global_sets[set_index],
        .dstBinding = 0,
        .dstArrayElement = 0,
        .descriptorCount = 1,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .pImageInfo = null,
        .pBufferInfo = buffer_info,
        .pTexelBufferView = null,
    };

    vk.vkUpdateDescriptorSets(context.device, 1, &write, 0, null);
}

/// Update a descriptor set with texture sampler info
pub fn updateTextureSet(
    context: *vk_context.VulkanContext,
    state: *MaterialShaderDescriptorState,
    set_index: u32,
    texture: *const resource_types.Texture,
) void {
    if (set_index >= MAX_DESCRIPTOR_SETS) {
        logger.err("Invalid descriptor set index: {}", .{set_index});
        return;
    }

    if (texture.internal_data == null) {
        logger.err("Texture has no internal data", .{});
        return;
    }

    const internal_data: *vulkan_texture.VulkanTexture = @ptrCast(@alignCast(texture.internal_data.?));

    var image_info: vk.VkDescriptorImageInfo = .{
        .sampler = internal_data.sampler,
        .imageView = internal_data.image.view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    var write: vk.VkWriteDescriptorSet = .{
        .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,
        .dstSet = state.global_sets[set_index],
        .dstBinding = 1,
        .dstArrayElement = 0,
        .descriptorCount = 1,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &image_info,
        .pBufferInfo = null,
        .pTexelBufferView = null,
    };

    vk.vkUpdateDescriptorSets(context.device, 1, &write, 0, null);
}

/// Update a descriptor set with both buffer and texture info
pub fn updateGlobalSetFull(
    context: *vk_context.VulkanContext,
    state: *MaterialShaderDescriptorState,
    set_index: u32,
    buffer_info: *const vk.VkDescriptorBufferInfo,
    texture: *const resource_types.Texture,
) void {
    if (set_index >= MAX_DESCRIPTOR_SETS) {
        logger.err("Invalid descriptor set index: {}", .{set_index});
        return;
    }

    if (texture.internal_data == null) {
        logger.err("Texture has no internal data", .{});
        return;
    }

    const internal_data: *vulkan_texture.VulkanTexture = @ptrCast(@alignCast(texture.internal_data.?));

    var image_info: vk.VkDescriptorImageInfo = .{
        .sampler = internal_data.sampler,
        .imageView = internal_data.image.view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    var writes: [2]vk.VkWriteDescriptorSet = .{
        // UBO binding
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = state.global_sets[set_index],
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = buffer_info,
            .pTexelBufferView = null,
        },
        // Texture sampler binding
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = state.global_sets[set_index],
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
    };

    vk.vkUpdateDescriptorSets(context.device, writes.len, &writes, 0, null);
}
