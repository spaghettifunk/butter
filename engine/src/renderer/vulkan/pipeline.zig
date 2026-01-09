//! Vulkan graphics pipeline management.
//!
//! Handles creation and destruction of graphics pipelines.

const std = @import("std");
const vk_context = @import("context.zig");
const vk = vk_context.vk;
const logger = @import("../../core/logging.zig");
const shader = @import("shader.zig");
const math = @import("../../math/math.zig");

// Re-export Vertex3D from math module for convenience
pub const Vertex3D = math.Vertex3D;

/// Push constant data for per-object rendering.
/// Push constants are small, fast-access data sent directly with draw commands.
/// Maximum size is typically 128 bytes on most hardware (256 bytes guaranteed by spec).
/// Total size: 128 bytes (expanded to support per-draw material parameters)
pub const PushConstantObject = extern struct {
    /// Model transformation matrix (64 bytes)
    model: math.Mat4 = math.mat4Identity(),

    /// Material tint color (16 bytes) - multiplied with diffuse texture
    tint_color: math.Vec4 = .{ .elements = .{ 1.0, 1.0, 1.0, 1.0 } },

    /// Material parameters (16 bytes)
    /// x: roughness (0-1), y: metallic (0-1), z: emission strength, w: padding
    material_params: math.Vec4 = .{ .elements = .{ 0.8, 0.0, 0.0, 0.0 } },

    /// UV transform: offset (8 bytes)
    uv_offset: math.Vec2 = .{ .elements = .{ 0.0, 0.0 } },

    /// UV transform: scale (8 bytes)
    uv_scale: math.Vec2 = .{ .elements = .{ 1.0, 1.0 } },

    /// Material flags (4 bytes)
    /// Bit 0: Use vertex colors, Bit 1: Use normal map, etc.
    flags: u32 = 0,

    /// Padding to align to 128 bytes (12 bytes)
    _pad: [3]u32 = .{ 0, 0, 0 },
};

// Compile-time assertion to ensure PushConstantObject is exactly 128 bytes
comptime {
    if (@sizeOf(PushConstantObject) != 128) {
        @compileError("PushConstantObject must be exactly 128 bytes");
    }
}

/// Push constant data for shadow map rendering.
/// Matches the material shader push constants structure for compatibility.
/// Total size: 84 bytes
pub const ShadowPushConstants = extern struct {
    /// Model transformation matrix (64 bytes)
    model: math.Mat4 = math.mat4Identity(),

    /// Material parameters (16 bytes) - unused in shadow pass but needed for struct compatibility
    material_params: math.Vec4 = .{ .elements = .{ 0.0, 0.0, 0.0, 0.0 } },

    /// Cascade index (0-3) for selecting the correct view-projection matrix (4 bytes)
    cascade_index: u32 = 0,
};

// Compile-time assertion to ensure ShadowPushConstants fits within push constant limits
comptime {
    if (@sizeOf(ShadowPushConstants) > 128) {
        @compileError("ShadowPushConstants exceeds 128 bytes");
    }
}

/// Vulkan graphics pipeline state
pub const VulkanPipeline = struct {
    handle: vk.VkPipeline = null,
    layout: vk.VkPipelineLayout = null,
};

/// Material shader - complete shader with pipeline and resources
pub const MaterialShader = struct {
    /// Vertex shader module
    vertex_shader: shader.VulkanShaderModule = .{},

    /// Fragment shader module
    fragment_shader: shader.VulkanShaderModule = .{},

    /// Graphics pipeline
    pipeline: VulkanPipeline = .{},
};

/// Grid shader - specialized shader for editor grid rendering
pub const GridShader = struct {
    /// Vertex shader module
    vertex_shader: shader.VulkanShaderModule = .{},

    /// Fragment shader module
    fragment_shader: shader.VulkanShaderModule = .{},

    /// Graphics pipeline
    pipeline: VulkanPipeline = .{},
};

/// Shadow pipeline - depth-only rendering for shadow maps
pub const ShadowPipeline = struct {
    /// Vertex shader module
    vertex_shader: shader.VulkanShaderModule = .{},

    /// Fragment shader module
    fragment_shader: shader.VulkanShaderModule = .{},

    /// Graphics pipeline
    pipeline: VulkanPipeline = .{},
};

/// Get vertex input binding description for Vertex3D
pub fn getVertexBindingDescription() vk.VkVertexInputBindingDescription {
    return .{
        .binding = 0,
        .stride = @sizeOf(Vertex3D),
        .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
    };
}

/// Get vertex attribute descriptions for Vertex3D (position + normal + texcoord + tangent + color)
pub fn getVertexAttributeDescriptions() [5]vk.VkVertexInputAttributeDescription {
    return .{
        // Position attribute (location 0)
        .{
            .location = 0,
            .binding = 0,
            .format = vk.VK_FORMAT_R32G32B32_SFLOAT,
            .offset = @offsetOf(Vertex3D, "position"),
        },
        // Normal attribute (location 1)
        .{
            .location = 1,
            .binding = 0,
            .format = vk.VK_FORMAT_R32G32B32_SFLOAT,
            .offset = @offsetOf(Vertex3D, "normal"),
        },
        // Texture coordinate attribute (location 2)
        .{
            .location = 2,
            .binding = 0,
            .format = vk.VK_FORMAT_R32G32_SFLOAT,
            .offset = @offsetOf(Vertex3D, "texcoord"),
        },
        // Tangent attribute (location 3)
        .{
            .location = 3,
            .binding = 0,
            .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT,
            .offset = @offsetOf(Vertex3D, "tangent"),
        },
        // Color attribute (location 4)
        .{
            .location = 4,
            .binding = 0,
            .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT, // Color is now vec4
            .offset = @offsetOf(Vertex3D, "color"),
        },
    };
}

/// Create the graphics pipeline for the material shader
/// Supports both legacy single descriptor set and new two-tier architecture
pub fn createMaterialPipeline(
    context: *vk_context.VulkanContext,
    material_shader: *MaterialShader,
    descriptor_layout: vk.VkDescriptorSetLayout,
    renderpass: vk.VkRenderPass,
) bool {
    return createMaterialPipelineWithLayouts(context, material_shader, descriptor_layout, null, renderpass);
}

/// Create the graphics pipeline for the material shader with explicit descriptor set layouts
/// For two-tier architecture: global_layout (Set 0), material_layout (Set 1), shadow_layout (Set 2)
/// For legacy: only global_layout is used (combined UBO + textures)
pub fn createMaterialPipelineWithLayouts(
    context: *vk_context.VulkanContext,
    material_shader: *MaterialShader,
    global_layout: vk.VkDescriptorSetLayout,
    material_layout: ?vk.VkDescriptorSetLayout,
    renderpass: vk.VkRenderPass,
) bool {
    return createMaterialPipelineWithShadow(context, material_shader, global_layout, material_layout, null, renderpass);
}

/// Create the graphics pipeline for the material shader with all descriptor set layouts
/// global_layout (Set 0), material_layout (Set 1), shadow_layout (Set 2)
pub fn createMaterialPipelineWithShadow(
    context: *vk_context.VulkanContext,
    material_shader: *MaterialShader,
    global_layout: vk.VkDescriptorSetLayout,
    material_layout: ?vk.VkDescriptorSetLayout,
    shadow_layout: ?vk.VkDescriptorSetLayout,
    renderpass: vk.VkRenderPass,
) bool {
    logger.debug("Creating material shader pipeline...", .{});

    // Shader stages
    var shader_stages: [2]vk.VkPipelineShaderStageCreateInfo = .{
        shader.createStageInfo(.{
            .module = material_shader.vertex_shader.handle,
            .stage = .vertex,
        }),
        shader.createStageInfo(.{
            .module = material_shader.fragment_shader.handle,
            .stage = .fragment,
        }),
    };

    // Vertex input
    var binding_description = getVertexBindingDescription();
    var attribute_descriptions = getVertexAttributeDescriptions();

    var vertex_input_info: vk.VkPipelineVertexInputStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = &binding_description,
        .vertexAttributeDescriptionCount = attribute_descriptions.len,
        .pVertexAttributeDescriptions = &attribute_descriptions,
    };

    // Input assembly
    var input_assembly: vk.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = vk.VK_FALSE,
    };

    // Viewport and scissor (dynamic state)
    var viewport_state: vk.VkPipelineViewportStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .pViewports = null, // Dynamic
        .scissorCount = 1,
        .pScissors = null, // Dynamic
    };

    // Rasterizer
    var rasterizer: vk.VkPipelineRasterizationStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthClampEnable = vk.VK_FALSE,
        .rasterizerDiscardEnable = vk.VK_FALSE,
        .polygonMode = vk.VK_POLYGON_MODE_FILL,
        .cullMode = vk.VK_CULL_MODE_BACK_BIT,
        .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .depthBiasEnable = vk.VK_FALSE,
        .depthBiasConstantFactor = 0.0,
        .depthBiasClamp = 0.0,
        .depthBiasSlopeFactor = 0.0,
        .lineWidth = 1.0,
    };

    // Multisampling (disabled)
    var multisampling: vk.VkPipelineMultisampleStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = vk.VK_FALSE,
        .minSampleShading = 1.0,
        .pSampleMask = null,
        .alphaToCoverageEnable = vk.VK_FALSE,
        .alphaToOneEnable = vk.VK_FALSE,
    };

    // Depth and stencil
    var depth_stencil: vk.VkPipelineDepthStencilStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthTestEnable = vk.VK_TRUE,
        .depthWriteEnable = vk.VK_TRUE,
        .depthCompareOp = vk.VK_COMPARE_OP_LESS,
        .depthBoundsTestEnable = vk.VK_FALSE,
        .stencilTestEnable = vk.VK_FALSE,
        .front = std.mem.zeroes(vk.VkStencilOpState),
        .back = std.mem.zeroes(vk.VkStencilOpState),
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
    };

    // Color blending (disabled)
    var color_blend_attachment: vk.VkPipelineColorBlendAttachmentState = .{
        .blendEnable = vk.VK_FALSE,
        .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
        .colorBlendOp = vk.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
        .alphaBlendOp = vk.VK_BLEND_OP_ADD,
        .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT |
            vk.VK_COLOR_COMPONENT_G_BIT |
            vk.VK_COLOR_COMPONENT_B_BIT |
            vk.VK_COLOR_COMPONENT_A_BIT,
    };

    var color_blending: vk.VkPipelineColorBlendStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .logicOpEnable = vk.VK_FALSE,
        .logicOp = vk.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
    };

    // Dynamic state
    var dynamic_states: [2]vk.VkDynamicState = .{
        vk.VK_DYNAMIC_STATE_VIEWPORT,
        vk.VK_DYNAMIC_STATE_SCISSOR,
    };

    var dynamic_state: vk.VkPipelineDynamicStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    // Push constant range for per-object data (model matrix + material parameters)
    // Accessible from both vertex shader (for transformations) and fragment shader (for material params)
    var push_constant_range: vk.VkPushConstantRange = .{
        .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(PushConstantObject),
    };

    // Pipeline layout - supports Set 0 (global UBO), Set 1 (material textures), Set 2 (shadow maps)
    var set_layouts: [3]vk.VkDescriptorSetLayout = undefined;
    var set_layout_count: u32 = 1;
    set_layouts[0] = global_layout;

    if (material_layout) |mat_layout| {
        set_layouts[1] = mat_layout;
        set_layout_count = 2;
    }

    if (shadow_layout) |shd_layout| {
        set_layouts[2] = shd_layout;
        set_layout_count = 3;
    }

    var layout_info: vk.VkPipelineLayoutCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = set_layout_count,
        .pSetLayouts = &set_layouts,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant_range,
    };

    var result = vk.vkCreatePipelineLayout(
        context.device,
        &layout_info,
        context.allocator,
        &material_shader.pipeline.layout,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreatePipelineLayout failed with result: {}", .{result});
        return false;
    }

    // Create the graphics pipeline
    var pipeline_info: vk.VkGraphicsPipelineCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stageCount = shader_stages.len,
        .pStages = &shader_stages,
        .pVertexInputState = &vertex_input_info,
        .pInputAssemblyState = &input_assembly,
        .pTessellationState = null,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state,
        .layout = material_shader.pipeline.layout,
        .renderPass = renderpass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    result = vk.vkCreateGraphicsPipelines(
        context.device,
        null, // pipeline cache
        1,
        &pipeline_info,
        context.allocator,
        &material_shader.pipeline.handle,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateGraphicsPipelines failed with result: {}", .{result});
        vk.vkDestroyPipelineLayout(context.device, material_shader.pipeline.layout, context.allocator);
        material_shader.pipeline.layout = null;
        return false;
    }

    logger.info("Material shader pipeline created.", .{});
    return true;
}

/// Destroy the material shader pipeline
pub fn destroyMaterialPipeline(
    context: *vk_context.VulkanContext,
    material_shader: *MaterialShader,
) void {
    if (context.device == null) return;

    if (material_shader.pipeline.handle) |handle| {
        vk.vkDestroyPipeline(context.device, handle, context.allocator);
        material_shader.pipeline.handle = null;
    }

    if (material_shader.pipeline.layout) |layout| {
        vk.vkDestroyPipelineLayout(context.device, layout, context.allocator);
        material_shader.pipeline.layout = null;
    }
}

/// Create the shadow pipeline (depth-only rendering for shadow maps)
pub fn createShadowPipeline(
    context: *vk_context.VulkanContext,
    shadow_pipeline: *ShadowPipeline,
    global_layout: vk.VkDescriptorSetLayout,
    renderpass: vk.VkRenderPass,
) bool {
    logger.debug("Creating shadow pipeline...", .{});

    // Load shadow shaders
    if (!shader.load(
        context,
        std.heap.page_allocator,
        "build/shaders/Builtin.ShadowMap.vert.spv",
        .vertex,
        &shadow_pipeline.vertex_shader,
    )) {
        logger.err("Failed to create shadow vertex shader module.", .{});
        return false;
    }

    if (!shader.load(
        context,
        std.heap.page_allocator,
        "build/shaders/Builtin.ShadowMap.frag.spv",
        .fragment,
        &shadow_pipeline.fragment_shader,
    )) {
        logger.err("Failed to create shadow fragment shader module.", .{});
        shader.destroy(context, &shadow_pipeline.vertex_shader);
        return false;
    }

    // Shader stages
    var shader_stages: [2]vk.VkPipelineShaderStageCreateInfo = undefined;

    shader_stages[0] = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
        .module = shadow_pipeline.vertex_shader.handle,
        .pName = "main",
        .pSpecializationInfo = null,
    };

    shader_stages[1] = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = shadow_pipeline.fragment_shader.handle,
        .pName = "main",
        .pSpecializationInfo = null,
    };

    // Vertex input (same as material shader - position, normal, texcoord)
    var binding_description: vk.VkVertexInputBindingDescription = .{
        .binding = 0,
        .stride = @sizeOf(Vertex3D),
        .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
    };

    var attribute_descriptions: [4]vk.VkVertexInputAttributeDescription = undefined;

    // Position
    attribute_descriptions[0] = .{
        .location = 0,
        .binding = 0,
        .format = vk.VK_FORMAT_R32G32B32_SFLOAT,
        .offset = @offsetOf(Vertex3D, "position"),
    };

    // Normal (not used in shadow shader but included for consistency)
    attribute_descriptions[1] = .{
        .location = 1,
        .binding = 0,
        .format = vk.VK_FORMAT_R32G32B32_SFLOAT,
        .offset = @offsetOf(Vertex3D, "normal"),
    };

    // Texcoord (not used in shadow shader but included for consistency)
    attribute_descriptions[2] = .{
        .location = 2,
        .binding = 0,
        .format = vk.VK_FORMAT_R32G32_SFLOAT,
        .offset = @offsetOf(Vertex3D, "texcoord"),
    };

    // Tangent (required by shader even though not used)
    attribute_descriptions[3] = .{
        .location = 3,
        .binding = 0,
        .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT,
        .offset = @offsetOf(Vertex3D, "tangent"),
    };

    var vertex_input_info: vk.VkPipelineVertexInputStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = &binding_description,
        .vertexAttributeDescriptionCount = attribute_descriptions.len,
        .pVertexAttributeDescriptions = &attribute_descriptions,
    };

    // Input assembly
    var input_assembly: vk.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = vk.VK_FALSE,
    };

    // Viewport and scissor (dynamic state)
    var viewport_state: vk.VkPipelineViewportStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .pViewports = null, // Dynamic
        .scissorCount = 1,
        .pScissors = null, // Dynamic
    };

    // Rasterizer (with depth bias enabled for shadow acne prevention)
    var rasterizer: vk.VkPipelineRasterizationStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthClampEnable = vk.VK_FALSE, // Disabled - feature not enabled on MoltenVK
        .rasterizerDiscardEnable = vk.VK_FALSE,
        .polygonMode = vk.VK_POLYGON_MODE_FILL,
        .cullMode = vk.VK_CULL_MODE_FRONT_BIT, // Front-face culling for shadows
        .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .depthBiasEnable = vk.VK_TRUE, // Enable depth bias
        .depthBiasConstantFactor = 0.0, // Will be set dynamically
        .depthBiasClamp = 0.0,
        .depthBiasSlopeFactor = 0.0, // Will be set dynamically
        .lineWidth = 1.0,
    };

    // Multisampling (disabled)
    var multisampling: vk.VkPipelineMultisampleStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = vk.VK_FALSE,
        .minSampleShading = 1.0,
        .pSampleMask = null,
        .alphaToCoverageEnable = vk.VK_FALSE,
        .alphaToOneEnable = vk.VK_FALSE,
    };

    // Depth and stencil (depth test and write enabled)
    var depth_stencil: vk.VkPipelineDepthStencilStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthTestEnable = vk.VK_TRUE,
        .depthWriteEnable = vk.VK_TRUE,
        .depthCompareOp = vk.VK_COMPARE_OP_LESS,
        .depthBoundsTestEnable = vk.VK_FALSE,
        .stencilTestEnable = vk.VK_FALSE,
        .front = std.mem.zeroes(vk.VkStencilOpState),
        .back = std.mem.zeroes(vk.VkStencilOpState),
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
    };

    // No color blending (depth-only rendering)
    var color_blending: vk.VkPipelineColorBlendStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .logicOpEnable = vk.VK_FALSE,
        .logicOp = vk.VK_LOGIC_OP_COPY,
        .attachmentCount = 0, // No color attachments
        .pAttachments = null,
        .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
    };

    // Dynamic state (viewport, scissor, and depth bias)
    var dynamic_states: [3]vk.VkDynamicState = .{
        vk.VK_DYNAMIC_STATE_VIEWPORT,
        vk.VK_DYNAMIC_STATE_SCISSOR,
        vk.VK_DYNAMIC_STATE_DEPTH_BIAS,
    };

    var dynamic_state: vk.VkPipelineDynamicStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    // Push constant range for model matrix and cascade index
    var push_constant_range: vk.VkPushConstantRange = .{
        .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
        .offset = 0,
        .size = @sizeOf(ShadowPushConstants),
    };

    // Pipeline layout (only global descriptor set for shadow UBO)
    var layout_info: vk.VkPipelineLayoutCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = &global_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant_range,
    };

    var result = vk.vkCreatePipelineLayout(
        context.device,
        &layout_info,
        context.allocator,
        &shadow_pipeline.pipeline.layout,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreatePipelineLayout (shadow) failed with result: {}", .{result});
        shader.destroy(context, &shadow_pipeline.vertex_shader);
        shader.destroy(context, &shadow_pipeline.fragment_shader);
        return false;
    }

    // Create the graphics pipeline
    var pipeline_info: vk.VkGraphicsPipelineCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stageCount = shader_stages.len,
        .pStages = &shader_stages,
        .pVertexInputState = &vertex_input_info,
        .pInputAssemblyState = &input_assembly,
        .pTessellationState = null,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state,
        .layout = shadow_pipeline.pipeline.layout,
        .renderPass = renderpass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    result = vk.vkCreateGraphicsPipelines(
        context.device,
        null, // pipeline cache
        1,
        &pipeline_info,
        context.allocator,
        &shadow_pipeline.pipeline.handle,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateGraphicsPipelines (shadow) failed with result: {}", .{result});
        vk.vkDestroyPipelineLayout(context.device, shadow_pipeline.pipeline.layout, context.allocator);
        shadow_pipeline.pipeline.layout = null;
        shader.destroy(context, &shadow_pipeline.vertex_shader);
        shader.destroy(context, &shadow_pipeline.fragment_shader);
        return false;
    }

    logger.info("Shadow pipeline created.", .{});
    return true;
}

/// Destroy the shadow pipeline
pub fn destroyShadowPipeline(
    context: *vk_context.VulkanContext,
    shadow_pipeline: *ShadowPipeline,
) void {
    if (context.device == null) return;

    if (shadow_pipeline.pipeline.handle) |handle| {
        vk.vkDestroyPipeline(context.device, handle, context.allocator);
        shadow_pipeline.pipeline.handle = null;
    }

    if (shadow_pipeline.pipeline.layout) |layout| {
        vk.vkDestroyPipelineLayout(context.device, layout, context.allocator);
        shadow_pipeline.pipeline.layout = null;
    }

    shader.destroy(context, &shadow_pipeline.vertex_shader);
    shader.destroy(context, &shadow_pipeline.fragment_shader);
}

/// Bind the object shader pipeline for rendering
pub fn bindPipeline(
    command_buffer: vk.VkCommandBuffer,
    pipe: *const VulkanPipeline,
) void {
    vk.vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.handle);
}

/// Bind descriptor sets for rendering
pub fn bindDescriptorSets(
    command_buffer: vk.VkCommandBuffer,
    layout: vk.VkPipelineLayout,
    first_set: u32,
    set_count: u32,
    sets: [*]const vk.VkDescriptorSet,
) void {
    vk.vkCmdBindDescriptorSets(
        command_buffer,
        vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        layout,
        first_set,
        set_count,
        sets,
        0,
        null,
    );
}

/// Push constants to the command buffer for per-object data
/// This is more efficient than updating uniform buffers for frequently changing data
/// Pushes to both vertex and fragment shader stages (128 bytes total)
pub fn pushConstants(
    command_buffer: vk.VkCommandBuffer,
    layout: vk.VkPipelineLayout,
    push_constant: *const PushConstantObject,
) void {
    vk.vkCmdPushConstants(
        command_buffer,
        layout,
        vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        @sizeOf(PushConstantObject),
        push_constant,
    );
}

/// Create the graphics pipeline for the grid shader
pub fn createGridPipeline(
    context: *vk_context.VulkanContext,
    grid_shader: *GridShader,
    descriptor_layout: vk.VkDescriptorSetLayout,
    renderpass: vk.VkRenderPass,
) bool {
    logger.debug("Creating grid shader pipeline...", .{});

    // Shader stages
    var shader_stages: [2]vk.VkPipelineShaderStageCreateInfo = .{
        shader.createStageInfo(.{
            .module = grid_shader.vertex_shader.handle,
            .stage = .vertex,
        }),
        shader.createStageInfo(.{
            .module = grid_shader.fragment_shader.handle,
            .stage = .fragment,
        }),
    };

    // Vertex input - only position (vec3)
    var binding_description = vk.VkVertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf([3]f32),
        .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
    };

    var attribute_descriptions = [1]vk.VkVertexInputAttributeDescription{
        .{
            .location = 0,
            .binding = 0,
            .format = vk.VK_FORMAT_R32G32B32_SFLOAT,
            .offset = 0,
        },
    };

    var vertex_input_info: vk.VkPipelineVertexInputStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = &binding_description,
        .vertexAttributeDescriptionCount = attribute_descriptions.len,
        .pVertexAttributeDescriptions = &attribute_descriptions,
    };

    // Input assembly
    var input_assembly: vk.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = vk.VK_FALSE,
    };

    // Viewport state (dynamic)
    var viewport_state: vk.VkPipelineViewportStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .pViewports = null,
        .scissorCount = 1,
        .pScissors = null,
    };

    // Rasterizer
    var rasterizer: vk.VkPipelineRasterizationStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthClampEnable = vk.VK_FALSE,
        .rasterizerDiscardEnable = vk.VK_FALSE,
        .polygonMode = vk.VK_POLYGON_MODE_FILL,
        .cullMode = vk.VK_CULL_MODE_NONE,
        .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .depthBiasEnable = vk.VK_FALSE,
        .depthBiasConstantFactor = 0.0,
        .depthBiasClamp = 0.0,
        .depthBiasSlopeFactor = 0.0,
        .lineWidth = 1.0,
    };

    // Multisampling
    var multisampling: vk.VkPipelineMultisampleStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = vk.VK_FALSE,
        .minSampleShading = 1.0,
        .pSampleMask = null,
        .alphaToCoverageEnable = vk.VK_FALSE,
        .alphaToOneEnable = vk.VK_FALSE,
    };

    // Depth stencil
    var depth_stencil: vk.VkPipelineDepthStencilStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthTestEnable = vk.VK_TRUE,
        .depthWriteEnable = vk.VK_FALSE,
        .depthCompareOp = vk.VK_COMPARE_OP_LESS_OR_EQUAL,
        .depthBoundsTestEnable = vk.VK_FALSE,
        .stencilTestEnable = vk.VK_FALSE,
        .front = std.mem.zeroes(vk.VkStencilOpState),
        .back = std.mem.zeroes(vk.VkStencilOpState),
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
    };

    // Color blending
    var color_blend_attachment: vk.VkPipelineColorBlendAttachmentState = .{
        .blendEnable = vk.VK_TRUE,
        .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
        .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = vk.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
        .alphaBlendOp = vk.VK_BLEND_OP_ADD,
        .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT |
            vk.VK_COLOR_COMPONENT_G_BIT |
            vk.VK_COLOR_COMPONENT_B_BIT |
            vk.VK_COLOR_COMPONENT_A_BIT,
    };

    var color_blending: vk.VkPipelineColorBlendStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .logicOpEnable = vk.VK_FALSE,
        .logicOp = vk.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
    };

    // Dynamic state
    var dynamic_states = [_]vk.VkDynamicState{
        vk.VK_DYNAMIC_STATE_VIEWPORT,
        vk.VK_DYNAMIC_STATE_SCISSOR,
    };

    var dynamic_state: vk.VkPipelineDynamicStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    // Pipeline layout
    var set_layouts = [1]vk.VkDescriptorSetLayout{descriptor_layout};

    var pipeline_layout_info: vk.VkPipelineLayoutCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = &set_layouts,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };

    var result = vk.vkCreatePipelineLayout(
        context.device,
        &pipeline_layout_info,
        context.allocator,
        &grid_shader.pipeline.layout,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreatePipelineLayout (grid) failed: {}", .{result});
        return false;
    }

    // Create graphics pipeline
    var pipeline_info: vk.VkGraphicsPipelineCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stageCount = shader_stages.len,
        .pStages = &shader_stages,
        .pVertexInputState = &vertex_input_info,
        .pInputAssemblyState = &input_assembly,
        .pTessellationState = null,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state,
        .layout = grid_shader.pipeline.layout,
        .renderPass = renderpass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    result = vk.vkCreateGraphicsPipelines(
        context.device,
        null,
        1,
        &pipeline_info,
        context.allocator,
        &grid_shader.pipeline.handle,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateGraphicsPipelines (grid) failed: {}", .{result});
        vk.vkDestroyPipelineLayout(context.device, grid_shader.pipeline.layout, context.allocator);
        grid_shader.pipeline.layout = null;
        return false;
    }

    logger.info("Grid pipeline created.", .{});
    return true;
}

/// Destroy the grid shader pipeline and modules
pub fn destroyGridShader(
    context: *vk_context.VulkanContext,
    grid_shader: *GridShader,
) void {
    if (context.device == null) return;

    if (grid_shader.pipeline.handle) |handle| {
        vk.vkDestroyPipeline(context.device, handle, context.allocator);
        grid_shader.pipeline.handle = null;
    }

    if (grid_shader.pipeline.layout) |layout| {
        vk.vkDestroyPipelineLayout(context.device, layout, context.allocator);
        grid_shader.pipeline.layout = null;
    }

    shader.destroy(context, &grid_shader.vertex_shader);
    shader.destroy(context, &grid_shader.fragment_shader);
}
