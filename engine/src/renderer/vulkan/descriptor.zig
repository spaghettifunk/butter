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
const renderer = @import("../renderer.zig");

/// Maximum descriptor sets that can be allocated for per-frame data
pub const MAX_DESCRIPTOR_SETS: usize = swapchain.MAX_SWAPCHAIN_IMAGES;

/// Maximum descriptor sets for materials (one per unique material)
pub const MAX_MATERIAL_DESCRIPTORS: usize = 128;

/// Global descriptor state (Set 0 - per-frame data: UBO only)
pub const GlobalDescriptorState = struct {
    /// Descriptor set layout for global UBO (camera, lights)
    global_layout: vk.VkDescriptorSetLayout = null,

    /// Descriptor pool for per-frame sets
    pool: vk.VkDescriptorPool = null,

    /// Descriptor sets (one per frame in flight)
    global_sets: [MAX_DESCRIPTOR_SETS]vk.VkDescriptorSet =
        [_]vk.VkDescriptorSet{null} ** MAX_DESCRIPTOR_SETS,
};

/// Material descriptor state (Set 1 - per-material data: textures only)
pub const MaterialDescriptorState = struct {
    /// Descriptor set layout for material textures (diffuse, specular)
    material_layout: vk.VkDescriptorSetLayout = null,

    /// Descriptor pool for per-material sets
    pool: vk.VkDescriptorPool = null,

    /// Allocated material descriptor sets count
    allocated_count: u32 = 0,
};

/// Descriptor state for grid shader
pub const GridShaderDescriptorState = struct {
    /// Descriptor set layout for grid shader (Camera + Grid UBOs)
    layout: vk.VkDescriptorSetLayout = null,

    /// Descriptor pool
    pool: vk.VkDescriptorPool = null,

    /// Descriptor sets (one per frame in flight)
    sets: [MAX_DESCRIPTOR_SETS]vk.VkDescriptorSet =
        [_]vk.VkDescriptorSet{null} ** MAX_DESCRIPTOR_SETS,
};

/// Shadow descriptor state (Set 2 - shadow map textures)
pub const ShadowDescriptorState = struct {
    /// Descriptor set layout for shadow maps
    layout: vk.VkDescriptorSetLayout = null,

    /// Descriptor pool
    pool: vk.VkDescriptorPool = null,

    /// Descriptor sets (one per frame in flight)
    sets: [MAX_DESCRIPTOR_SETS]vk.VkDescriptorSet =
        [_]vk.VkDescriptorSet{null} ** MAX_DESCRIPTOR_SETS,
};

/// Create the global descriptor set layout (Set 0: GlobalUBO + ShadowUBO)
/// This is the new two-tier architecture where textures are in Set 1
pub fn createGlobalLayout(
    context: *vk_context.VulkanContext,
    state: *GlobalDescriptorState,
) bool {
    // Set 0, Binding 0: Global UBO (camera, lights, etc.)
    // Set 0, Binding 1: Shadow UBO (shadow matrices and params)
    var layout_bindings: [2]vk.VkDescriptorSetLayoutBinding = .{
        .{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
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
        logger.err("vkCreateDescriptorSetLayout (global) failed with result: {}", .{result});
        return false;
    }

    logger.debug("Global descriptor set layout created (Set 0: UBO only).", .{});
    return true;
}

/// Create the material descriptor set layout (Set 1: PBR Textures - 8 bindings)
pub fn createMaterialLayout(
    context: *vk_context.VulkanContext,
    state: *MaterialDescriptorState,
) bool {
    // Set 1: PBR Material textures (8 bindings)
    var layout_bindings: [8]vk.VkDescriptorSetLayoutBinding = .{
        // Binding 0: Albedo texture
        .{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 1: Metallic-Roughness texture
        .{
            .binding = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 2: Normal texture
        .{
            .binding = 2,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 3: AO texture
        .{
            .binding = 3,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 4: Emissive texture
        .{
            .binding = 4,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 5: Irradiance cubemap (IBL)
        .{
            .binding = 5,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 6: Prefiltered environment cubemap (IBL)
        .{
            .binding = 6,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 7: BRDF LUT
        .{
            .binding = 7,
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
        &state.material_layout,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateDescriptorSetLayout (material) failed with result: {}", .{result});
        return false;
    }

    logger.debug("Material descriptor set layout created (Set 1: 8 PBR textures).", .{});
    return true;
}

/// Destroy the global descriptor set layout
pub fn destroyGlobalLayout(
    context: *vk_context.VulkanContext,
    state: *GlobalDescriptorState,
) void {
    if (context.device == null) return;

    if (state.global_layout) |layout| {
        vk.vkDestroyDescriptorSetLayout(context.device, layout, context.allocator);
        state.global_layout = null;
    }
}

/// Destroy the material descriptor set layout
pub fn destroyMaterialLayout(
    context: *vk_context.VulkanContext,
    state: *MaterialDescriptorState,
) void {
    if (context.device == null) return;

    if (state.material_layout) |layout| {
        vk.vkDestroyDescriptorSetLayout(context.device, layout, context.allocator);
        state.material_layout = null;
    }
}

/// Create the global descriptor pool (for per-frame UBO sets)
/// This is the new two-tier architecture where only UBOs are in the global pool
pub fn createGlobalPool(
    context: *vk_context.VulkanContext,
    state: *GlobalDescriptorState,
    max_sets: u32,
) bool {
    // Pool size for uniform buffers (GlobalUBO + ShadowUBO per frame)
    var pool_sizes: [1]vk.VkDescriptorPoolSize = .{
        .{
            .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = max_sets * 2, // 2 UBOs per set (GlobalUBO + ShadowUBO)
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
        logger.err("vkCreateDescriptorPool (global) failed with result: {}", .{result});
        return false;
    }

    logger.debug("Global descriptor pool created.", .{});
    return true;
}

/// Create the material descriptor pool (for per-material texture sets)
pub fn createMaterialPool(
    context: *vk_context.VulkanContext,
    state: *MaterialDescriptorState,
) bool {
    // Pool size for 8 texture samplers per material
    var pool_sizes: [1]vk.VkDescriptorPoolSize = .{
        .{
            .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = MAX_MATERIAL_DESCRIPTORS * 8, // 8 PBR textures per material
        },
    };

    var pool_info: vk.VkDescriptorPoolCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = MAX_MATERIAL_DESCRIPTORS,
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
        logger.err("vkCreateDescriptorPool (material) failed with result: {}", .{result});
        return false;
    }

    logger.debug("Material descriptor pool created (max {} materials, 8 textures each).", .{MAX_MATERIAL_DESCRIPTORS});
    return true;
}

/// Destroy the global descriptor pool (also frees all descriptor sets)
pub fn destroyGlobalPool(
    context: *vk_context.VulkanContext,
    state: *GlobalDescriptorState,
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

/// Destroy the material descriptor pool (also frees all descriptor sets)
pub fn destroyMaterialPool(
    context: *vk_context.VulkanContext,
    state: *MaterialDescriptorState,
) void {
    if (context.device == null) return;

    if (state.pool) |pool| {
        vk.vkDestroyDescriptorPool(context.device, pool, context.allocator);
        state.pool = null;
    }

    state.allocated_count = 0;
}

/// Allocate global descriptor sets from the pool
pub fn allocateGlobalSets(
    context: *vk_context.VulkanContext,
    state: *GlobalDescriptorState,
    count: u32,
) bool {
    if (state.pool == null or state.global_layout == null) {
        logger.err("Cannot allocate global descriptor sets: pool or layout is null", .{});
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
        logger.err("vkAllocateDescriptorSets (global) failed with result: {}", .{result});
        return false;
    }

    logger.debug("Allocated {} global descriptor sets.", .{count});
    return true;
}

/// Allocate a single material descriptor set
pub fn allocateMaterialSet(
    context: *vk_context.VulkanContext,
    state: *MaterialDescriptorState,
) ?vk.VkDescriptorSet {
    if (state.pool == null or state.material_layout == null) {
        logger.err("Cannot allocate material descriptor set: pool or layout is null", .{});
        return null;
    }

    if (state.allocated_count >= MAX_MATERIAL_DESCRIPTORS) {
        logger.warn("Material descriptor pool exhausted ({} / {} sets)", .{ state.allocated_count, MAX_MATERIAL_DESCRIPTORS });
        return null;
    }

    var descriptor_set: vk.VkDescriptorSet = null;
    var layouts: [1]vk.VkDescriptorSetLayout = .{state.material_layout};

    var alloc_info: vk.VkDescriptorSetAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = state.pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &layouts,
    };

    const result = vk.vkAllocateDescriptorSets(
        context.device,
        &alloc_info,
        &descriptor_set,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkAllocateDescriptorSets (material) failed with result: {}", .{result});
        return null;
    }

    state.allocated_count += 1;
    logger.debug("Allocated material descriptor set ({} / {}).", .{ state.allocated_count, MAX_MATERIAL_DESCRIPTORS });
    return descriptor_set;
}

/// Free a material descriptor set (note: with current Vulkan, sets are freed when pool is reset/destroyed)
pub fn freeMaterialSet(
    _: *vk_context.VulkanContext,
    state: *MaterialDescriptorState,
) void {
    // Note: Individual descriptor sets cannot be freed in Vulkan
    // They are automatically freed when the pool is destroyed
    // We just decrement the counter for tracking
    if (state.allocated_count > 0) {
        state.allocated_count -= 1;
    }
}

/// Update a global descriptor set with buffer info (GlobalUBO at binding 0)
pub fn updateGlobalSet(
    context: *vk_context.VulkanContext,
    state: *GlobalDescriptorState,
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

/// Update a global descriptor set with shadow UBO buffer info (binding 1)
pub fn updateShadowSet(
    context: *vk_context.VulkanContext,
    state: *GlobalDescriptorState,
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
        .dstBinding = 1,
        .dstArrayElement = 0,
        .descriptorCount = 1,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .pImageInfo = null,
        .pBufferInfo = buffer_info,
        .pTexelBufferView = null,
    };

    vk.vkUpdateDescriptorSets(context.device, 1, &write, 0, null);
}

/// Legacy function for backward compatibility
pub fn updateMaterialSet(
    context: *vk_context.VulkanContext,
    descriptor_set: vk.VkDescriptorSet,
    diffuse_texture: *const resource_types.Texture,
    specular_texture: *const resource_types.Texture,
) void {
    // Map legacy diffuse/specular to albedo/metallic-roughness
    updateMaterialSetPBR(
        context,
        descriptor_set,
        diffuse_texture, // albedo
        specular_texture, // metallic-roughness
        diffuse_texture, // normal (fallback to albedo if not available)
        diffuse_texture, // ao (fallback)
        diffuse_texture, // emissive (fallback)
        diffuse_texture, // irradiance (fallback - will be replaced in Phase 2)
        diffuse_texture, // prefiltered (fallback - will be replaced in Phase 2)
        diffuse_texture, // brdf_lut (fallback - will be replaced in Phase 2)
    );
}

/// Update a material descriptor set with all 8 PBR textures
pub fn updateMaterialSetPBR(
    context: *vk_context.VulkanContext,
    descriptor_set: vk.VkDescriptorSet,
    albedo_texture: *const resource_types.Texture,
    metallic_roughness_texture: *const resource_types.Texture,
    normal_texture: *const resource_types.Texture,
    ao_texture: *const resource_types.Texture,
    emissive_texture: *const resource_types.Texture,
    irradiance_texture: *const resource_types.Texture,
    prefiltered_texture: *const resource_types.Texture,
    brdf_lut_texture: *const resource_types.Texture,
) void {
    // Validate all textures have internal data
    const textures = [_]*const resource_types.Texture{
        albedo_texture,
        metallic_roughness_texture,
        normal_texture,
        ao_texture,
        emissive_texture,
        irradiance_texture,
        prefiltered_texture,
        brdf_lut_texture,
    };

    for (textures) |tex| {
        if (tex.internal_data == null) {
            logger.err("Texture has no internal data", .{});
            return;
        }
    }

    // Get internal Vulkan texture data
    const albedo_internal: *vulkan_texture.VulkanTexture = @ptrCast(@alignCast(albedo_texture.internal_data.?));
    const metallic_roughness_internal: *vulkan_texture.VulkanTexture = @ptrCast(@alignCast(metallic_roughness_texture.internal_data.?));
    const normal_internal: *vulkan_texture.VulkanTexture = @ptrCast(@alignCast(normal_texture.internal_data.?));
    const ao_internal: *vulkan_texture.VulkanTexture = @ptrCast(@alignCast(ao_texture.internal_data.?));
    const emissive_internal: *vulkan_texture.VulkanTexture = @ptrCast(@alignCast(emissive_texture.internal_data.?));
    const irradiance_internal: *vulkan_texture.VulkanTexture = @ptrCast(@alignCast(irradiance_texture.internal_data.?));
    const prefiltered_internal: *vulkan_texture.VulkanTexture = @ptrCast(@alignCast(prefiltered_texture.internal_data.?));
    const brdf_lut_internal: *vulkan_texture.VulkanTexture = @ptrCast(@alignCast(brdf_lut_texture.internal_data.?));

    // Prepare descriptor image infos
    var albedo_info: vk.VkDescriptorImageInfo = .{
        .sampler = albedo_internal.sampler,
        .imageView = albedo_internal.image.view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    var metallic_roughness_info: vk.VkDescriptorImageInfo = .{
        .sampler = metallic_roughness_internal.sampler,
        .imageView = metallic_roughness_internal.image.view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    var normal_info: vk.VkDescriptorImageInfo = .{
        .sampler = normal_internal.sampler,
        .imageView = normal_internal.image.view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    var ao_info: vk.VkDescriptorImageInfo = .{
        .sampler = ao_internal.sampler,
        .imageView = ao_internal.image.view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    var emissive_info: vk.VkDescriptorImageInfo = .{
        .sampler = emissive_internal.sampler,
        .imageView = emissive_internal.image.view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    var irradiance_info: vk.VkDescriptorImageInfo = .{
        .sampler = irradiance_internal.sampler,
        .imageView = irradiance_internal.image.view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    var prefiltered_info: vk.VkDescriptorImageInfo = .{
        .sampler = prefiltered_internal.sampler,
        .imageView = prefiltered_internal.image.view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    var brdf_lut_info: vk.VkDescriptorImageInfo = .{
        .sampler = brdf_lut_internal.sampler,
        .imageView = brdf_lut_internal.image.view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    // Prepare write descriptor sets for all 8 textures
    var writes: [8]vk.VkWriteDescriptorSet = .{
        // Binding 0: Albedo
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &albedo_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        // Binding 1: Metallic-Roughness
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &metallic_roughness_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        // Binding 2: Normal
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 2,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &normal_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        // Binding 3: AO
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 3,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &ao_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        // Binding 4: Emissive
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 4,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &emissive_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        // Binding 5: Irradiance
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 5,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &irradiance_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        // Binding 6: Prefiltered
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 6,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &prefiltered_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        // Binding 7: BRDF LUT
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 7,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &brdf_lut_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
    };

    vk.vkUpdateDescriptorSets(context.device, writes.len, &writes, 0, null);
}

/// Create the grid descriptor set layout
pub fn createGridLayout(
    context: *vk_context.VulkanContext,
    state: *GridShaderDescriptorState,
) bool {
    // Grid shader bindings:
    // - Binding 0: Camera UBO (view_proj matrix)
    // - Binding 1: Grid UBO (grid parameters and colors)
    var layout_bindings: [2]vk.VkDescriptorSetLayoutBinding = .{
        // Camera UBO: set 0, binding 0
        .{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        },
        // Grid UBO: set 0, binding 1
        .{
            .binding = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
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
        &state.layout,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateDescriptorSetLayout (grid) failed: {}", .{result});
        return false;
    }

    logger.debug("Grid descriptor set layout created.", .{});
    return true;
}

/// Destroy grid descriptor set layout
pub fn destroyGridLayout(
    context: *vk_context.VulkanContext,
    state: *GridShaderDescriptorState,
) void {
    if (context.device == null) return;

    if (state.layout) |layout| {
        vk.vkDestroyDescriptorSetLayout(context.device, layout, context.allocator);
        state.layout = null;
    }
}

/// Create grid descriptor pool
pub fn createGridPool(
    context: *vk_context.VulkanContext,
    state: *GridShaderDescriptorState,
    max_sets: u32,
) bool {
    // Pool sizes for 2 UBOs per frame
    var pool_sizes: [1]vk.VkDescriptorPoolSize = .{
        .{
            .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = max_sets * 2, // Camera UBO + Grid UBO per frame
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
        logger.err("vkCreateDescriptorPool (grid) failed: {}", .{result});
        return false;
    }

    logger.debug("Grid descriptor pool created.", .{});
    return true;
}

/// Destroy grid descriptor pool
pub fn destroyGridPool(
    context: *vk_context.VulkanContext,
    state: *GridShaderDescriptorState,
) void {
    if (context.device == null) return;

    if (state.pool) |pool| {
        vk.vkDestroyDescriptorPool(context.device, pool, context.allocator);
        state.pool = null;
    }

    for (&state.sets) |*set| {
        set.* = null;
    }
}

/// Allocate grid descriptor sets
pub fn allocateGridSets(
    context: *vk_context.VulkanContext,
    state: *GridShaderDescriptorState,
    count: u32,
) bool {
    if (state.pool == null or state.layout == null) {
        logger.err("Cannot allocate grid descriptor sets: pool or layout is null", .{});
        return false;
    }

    if (count > MAX_DESCRIPTOR_SETS) {
        logger.err("Cannot allocate {} grid descriptor sets (max: {})", .{ count, MAX_DESCRIPTOR_SETS });
        return false;
    }

    var layouts: [MAX_DESCRIPTOR_SETS]vk.VkDescriptorSetLayout = undefined;
    for (0..count) |i| {
        layouts[i] = state.layout;
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
        &state.sets,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkAllocateDescriptorSets (grid) failed: {}", .{result});
        return false;
    }

    logger.debug("Allocated {} grid descriptor sets.", .{count});
    return true;
}

/// Update grid descriptor set with both UBOs
pub fn updateGridSet(
    context: *vk_context.VulkanContext,
    state: *GridShaderDescriptorState,
    set_index: u32,
    camera_buffer: vk.VkBuffer,
    grid_buffer: vk.VkBuffer,
) void {
    if (set_index >= MAX_DESCRIPTOR_SETS) return;

    var camera_buffer_info = vk.VkDescriptorBufferInfo{
        .buffer = camera_buffer,
        .offset = 0,
        .range = @sizeOf(renderer.GridCameraUBO),
    };

    var grid_buffer_info = vk.VkDescriptorBufferInfo{
        .buffer = grid_buffer,
        .offset = 0,
        .range = @sizeOf(renderer.GridUBO),
    };

    var write_descriptors = [2]vk.VkWriteDescriptorSet{
        // Camera UBO at binding 0
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = state.sets[set_index],
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &camera_buffer_info,
            .pTexelBufferView = null,
        },
        // Grid UBO at binding 1
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = state.sets[set_index],
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &grid_buffer_info,
            .pTexelBufferView = null,
        },
    };

    vk.vkUpdateDescriptorSets(
        context.device,
        write_descriptors.len,
        &write_descriptors,
        0,
        null,
    );
}

// =========================================================================
// Shadow Descriptor Functions (Set 2)
// =========================================================================

/// Create shadow descriptor set layout (Set 2: shadow map textures)
pub fn createShadowLayout(
    context: *vk_context.VulkanContext,
    state: *ShadowDescriptorState,
) bool {
    // Set 2, Binding 0: Directional cascade shadow maps (sampler2DArray with 4 layers)
    // Set 2, Binding 1: Point light shadow cubemaps (samplerCubeArray - for Phase 4)
    var layout_bindings: [2]vk.VkDescriptorSetLayoutBinding = .{
        .{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 4, // 4 cascade layers
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 4, // Up to 4 point light shadow cubemaps
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
        &state.layout,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateDescriptorSetLayout (shadow) failed: {}", .{result});
        return false;
    }

    logger.debug("Shadow descriptor set layout created (Set 2).", .{});
    return true;
}

/// Destroy shadow descriptor set layout
pub fn destroyShadowLayout(
    context: *vk_context.VulkanContext,
    state: *ShadowDescriptorState,
) void {
    if (context.device == null) return;

    if (state.layout) |layout| {
        vk.vkDestroyDescriptorSetLayout(context.device, layout, context.allocator);
        state.layout = null;
    }
}

/// Create shadow descriptor pool
pub fn createShadowPool(
    context: *vk_context.VulkanContext,
    state: *ShadowDescriptorState,
    max_sets: u32,
) bool {
    // Pool sizes for shadow map textures (cascades + point lights)
    var pool_sizes: [1]vk.VkDescriptorPoolSize = .{
        .{
            .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = max_sets * 8, // 4 cascades + 4 point cubemaps per set
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
        logger.err("vkCreateDescriptorPool (shadow) failed: {}", .{result});
        return false;
    }

    logger.debug("Shadow descriptor pool created.", .{});
    return true;
}

/// Destroy shadow descriptor pool
pub fn destroyShadowPool(
    context: *vk_context.VulkanContext,
    state: *ShadowDescriptorState,
) void {
    if (context.device == null) return;

    if (state.pool) |pool| {
        vk.vkDestroyDescriptorPool(context.device, pool, context.allocator);
        state.pool = null;
    }

    for (&state.sets) |*set| {
        set.* = null;
    }
}

/// Allocate shadow descriptor sets
pub fn allocateShadowSets(
    context: *vk_context.VulkanContext,
    state: *ShadowDescriptorState,
    count: u32,
) bool {
    if (state.pool == null or state.layout == null) {
        logger.err("Cannot allocate shadow descriptor sets: pool or layout is null", .{});
        return false;
    }

    if (count > MAX_DESCRIPTOR_SETS) {
        logger.err("Cannot allocate {} shadow descriptor sets (max: {})", .{ count, MAX_DESCRIPTOR_SETS });
        return false;
    }

    var layouts: [MAX_DESCRIPTOR_SETS]vk.VkDescriptorSetLayout = undefined;
    for (0..count) |i| {
        layouts[i] = state.layout;
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
        &state.sets,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkAllocateDescriptorSets (shadow) failed: {}", .{result});
        return false;
    }

    logger.debug("Allocated {} shadow descriptor sets.", .{count});
    return true;
}

/// Update shadow descriptor set with cascade shadow map textures
pub fn updateShadowDescriptorSet(
    context: *vk_context.VulkanContext,
    state: *ShadowDescriptorState,
    set_index: u32,
    cascade_image_infos: []const vk.VkDescriptorImageInfo,
) void {
    if (set_index >= MAX_DESCRIPTOR_SETS) return;
    if (cascade_image_infos.len != 4) {
        logger.err("Expected 4 cascade shadow maps, got {}", .{cascade_image_infos.len});
        return;
    }

    var write: vk.VkWriteDescriptorSet = .{
        .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,
        .dstSet = state.sets[set_index],
        .dstBinding = 0,
        .dstArrayElement = 0,
        .descriptorCount = @intCast(cascade_image_infos.len),
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = cascade_image_infos.ptr,
        .pBufferInfo = null,
        .pTexelBufferView = null,
    };

    vk.vkUpdateDescriptorSets(context.device, 1, &write, 0, null);
}

/// Update shadow descriptor set with point light shadow cubemaps
pub fn updatePointShadowDescriptorSet(
    context: *vk_context.VulkanContext,
    state: *ShadowDescriptorState,
    set_index: u32,
    point_image_infos: []const vk.VkDescriptorImageInfo,
) void {
    if (set_index >= MAX_DESCRIPTOR_SETS) return;
    if (point_image_infos.len == 0 or point_image_infos.len > 4) {
        logger.err("Expected 1-4 point shadow cubemaps, got {}", .{point_image_infos.len});
        return;
    }

    var write: vk.VkWriteDescriptorSet = .{
        .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,
        .dstSet = state.sets[set_index],
        .dstBinding = 1,
        .dstArrayElement = 0,
        .descriptorCount = @intCast(point_image_infos.len),
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = point_image_infos.ptr,
        .pBufferInfo = null,
        .pTexelBufferView = null,
    };

    vk.vkUpdateDescriptorSets(context.device, 1, &write, 0, null);
}
