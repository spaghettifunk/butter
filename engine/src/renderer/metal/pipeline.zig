//! Metal graphics pipeline management.
//!
//! Handles creation and destruction of MTLRenderPipelineState and
//! MTLDepthStencilState objects.

const std = @import("std");
const metal_context = @import("context.zig");
const shader = @import("shader.zig");
const logger = @import("../../core/logging.zig");
const math = @import("../../math/math.zig");

const MetalContext = metal_context.MetalContext;
const sel = metal_context.sel_registerName;
const msg = metal_context.msgSend;
const msg1 = metal_context.msgSend1;
const msg2 = metal_context.msgSend2;
const msg3 = metal_context.msgSend3;
const getClass = metal_context.objc_getClass;
const release = metal_context.release;

// Re-export Vertex3D from math module for convenience
pub const Vertex3D = math.Vertex3D;

/// Push constant data for per-object rendering.
/// This is passed via setVertexBytes in Metal (equivalent to Vulkan push constants).
/// Total size: 64 bytes (model matrix only)
pub const PushConstantObject = extern struct {
    /// Model transformation matrix (64 bytes)
    model: math.Mat4 = math.mat4Identity(),
};

/// Metal graphics pipeline state
pub const MetalPipeline = struct {
    state: metal_context.MTLRenderPipelineState = null,
    depth_stencil_state: metal_context.MTLDepthStencilState = null,
};

/// Material shader - complete shader with pipeline and resources
pub const MaterialShader = struct {
    vertex_shader: shader.MetalShaderModule = .{},
    fragment_shader: shader.MetalShaderModule = .{},
    pipeline: MetalPipeline = .{},
};

/// Create the graphics pipeline for the material shader
pub fn createMaterialPipeline(
    context: *MetalContext,
    vertex_function: ?*anyopaque,
    fragment_function: ?*anyopaque,
    color_format: u64,
    depth_format: u64,
) ?MetalPipeline {
    const device = context.device orelse {
        logger.err("Cannot create pipeline: no Metal device", .{});
        return null;
    };

    if (vertex_function == null or fragment_function == null) {
        logger.err("Cannot create pipeline: null shader functions", .{});
        return null;
    }

    logger.debug("Creating material shader pipeline...", .{});

    // Create render pipeline descriptor
    const desc_class = getClass("MTLRenderPipelineDescriptor") orelse {
        logger.err("Failed to get MTLRenderPipelineDescriptor class", .{});
        return null;
    };

    const desc_alloc = msg(?*anyopaque, desc_class, sel("alloc"));
    if (desc_alloc == null) return null;

    const desc = msg(?*anyopaque, desc_alloc, sel("init"));
    if (desc == null) return null;

    // Set vertex and fragment functions
    _ = msg1(void, desc, sel("setVertexFunction:"), vertex_function);
    _ = msg1(void, desc, sel("setFragmentFunction:"), fragment_function);

    // Configure color attachment
    const color_attachments = msg(?*anyopaque, desc, sel("colorAttachments"));
    if (color_attachments) |attachments| {
        const attachment = msg1(?*anyopaque, attachments, sel("objectAtIndexedSubscript:"), @as(u64, 0));
        if (attachment) |att| {
            _ = msg1(void, att, sel("setPixelFormat:"), color_format);

            // Enable blending for transparency support
            _ = msg1(void, att, sel("setBlendingEnabled:"), @as(i8, 0)); // Disable for now
        }
    }

    // Set depth attachment format
    _ = msg1(void, desc, sel("setDepthAttachmentPixelFormat:"), depth_format);

    // Configure vertex descriptor for Vertex3D layout
    const vertex_desc = createVertexDescriptor() orelse {
        logger.err("Failed to create vertex descriptor", .{});
        release(desc);
        return null;
    };
    _ = msg1(void, desc, sel("setVertexDescriptor:"), vertex_desc);

    // Create pipeline state
    var error_ptr: ?*anyopaque = null;
    const pipeline_state = msg2(
        ?*anyopaque,
        device,
        sel("newRenderPipelineStateWithDescriptor:error:"),
        desc,
        &error_ptr,
    );

    release(desc);

    if (pipeline_state == null) {
        if (error_ptr) |err| {
            const err_desc = msg(?*anyopaque, err, sel("localizedDescription"));
            if (err_desc) |d| {
                const c_str = msg([*:0]const u8, d, sel("UTF8String"));
                logger.err("Pipeline creation failed: {s}", .{c_str});
            }
        } else {
            logger.err("Pipeline creation failed: unknown error", .{});
        }
        return null;
    }

    // Create depth stencil state
    const depth_stencil_state = createDepthStencilState(device) orelse {
        logger.err("Failed to create depth stencil state", .{});
        release(pipeline_state);
        return null;
    };

    logger.info("Material shader pipeline created.", .{});

    return MetalPipeline{
        .state = pipeline_state,
        .depth_stencil_state = depth_stencil_state,
    };
}

/// Create vertex descriptor matching Vertex3D layout
fn createVertexDescriptor() ?*anyopaque {
    const desc_class = getClass("MTLVertexDescriptor") orelse return null;

    const desc = msg(?*anyopaque, desc_class, sel("vertexDescriptor"));
    if (desc == null) return null;

    // Get attributes array
    const attributes = msg(?*anyopaque, desc, sel("attributes"));
    if (attributes == null) return null;

    // Buffer indices:
    // 0 = PushConstants (model matrix)
    // 1 = GlobalUBO (uniform buffer)
    // 2 = Vertex data (from vertex descriptor)
    const VERTEX_BUFFER_INDEX: u64 = 2;

    // Attribute 0: position (float3) at offset 0
    const attr0 = msg1(?*anyopaque, attributes, sel("objectAtIndexedSubscript:"), @as(u64, 0));
    if (attr0) |attr| {
        _ = msg1(void, attr, sel("setFormat:"), metal_context.MTLVertexFormat.Float3);
        _ = msg1(void, attr, sel("setOffset:"), @as(u64, 0));
        _ = msg1(void, attr, sel("setBufferIndex:"), VERTEX_BUFFER_INDEX);
    }

    // Attribute 1: normal (float3) at offset 12
    const attr1 = msg1(?*anyopaque, attributes, sel("objectAtIndexedSubscript:"), @as(u64, 1));
    if (attr1) |attr| {
        _ = msg1(void, attr, sel("setFormat:"), metal_context.MTLVertexFormat.Float3);
        _ = msg1(void, attr, sel("setOffset:"), @as(u64, 12));
        _ = msg1(void, attr, sel("setBufferIndex:"), VERTEX_BUFFER_INDEX);
    }

    // Attribute 2: texcoord (float2) at offset 24
    const attr2 = msg1(?*anyopaque, attributes, sel("objectAtIndexedSubscript:"), @as(u64, 2));
    if (attr2) |attr| {
        _ = msg1(void, attr, sel("setFormat:"), metal_context.MTLVertexFormat.Float2);
        _ = msg1(void, attr, sel("setOffset:"), @as(u64, 24));
        _ = msg1(void, attr, sel("setBufferIndex:"), VERTEX_BUFFER_INDEX);
    }

    // Attribute 3: tangent (float4) at offset 32
    const attr3 = msg1(?*anyopaque, attributes, sel("objectAtIndexedSubscript:"), @as(u64, 3));
    if (attr3) |attr| {
        _ = msg1(void, attr, sel("setFormat:"), metal_context.MTLVertexFormat.Float4);
        _ = msg1(void, attr, sel("setOffset:"), @as(u64, 32));
        _ = msg1(void, attr, sel("setBufferIndex:"), VERTEX_BUFFER_INDEX);
    }

    // Attribute 4: color (float4) at offset 48
    const attr4 = msg1(?*anyopaque, attributes, sel("objectAtIndexedSubscript:"), @as(u64, 4));
    if (attr4) |attr| {
        _ = msg1(void, attr, sel("setFormat:"), metal_context.MTLVertexFormat.Float4);
        _ = msg1(void, attr, sel("setOffset:"), @as(u64, 48));
        _ = msg1(void, attr, sel("setBufferIndex:"), VERTEX_BUFFER_INDEX);
    }

    // Get layouts array and configure buffer layout
    const layouts = msg(?*anyopaque, desc, sel("layouts"));
    if (layouts) |l| {
        const layout = msg1(?*anyopaque, l, sel("objectAtIndexedSubscript:"), VERTEX_BUFFER_INDEX);
        if (layout) |lay| {
            // Stride = sizeof(Vertex3D) = 64 bytes
            _ = msg1(void, lay, sel("setStride:"), @as(u64, @sizeOf(Vertex3D)));
            _ = msg1(void, lay, sel("setStepFunction:"), metal_context.MTLVertexStepFunction.PerVertex);
            _ = msg1(void, lay, sel("setStepRate:"), @as(u64, 1));
        }
    }

    return desc;
}

/// Create depth stencil state for depth testing
fn createDepthStencilState(device: ?*anyopaque) ?*anyopaque {
    const desc_class = getClass("MTLDepthStencilDescriptor") orelse return null;

    const desc_alloc = msg(?*anyopaque, desc_class, sel("alloc"));
    if (desc_alloc == null) return null;

    const desc = msg(?*anyopaque, desc_alloc, sel("init"));
    if (desc == null) return null;

    // Enable depth testing (match Vulkan: less-than comparison)
    _ = msg1(void, desc, sel("setDepthCompareFunction:"), metal_context.MTLCompareFunction.Less);
    _ = msg1(void, desc, sel("setDepthWriteEnabled:"), @as(i8, 1)); // YES

    // Create state
    const state = msg1(?*anyopaque, device, sel("newDepthStencilStateWithDescriptor:"), desc);
    release(desc);

    return state;
}

/// Destroy a pipeline and release resources
pub fn destroy(context: *MetalContext, pipeline: *MetalPipeline) void {
    _ = context;

    if (pipeline.depth_stencil_state) |state| {
        release(state);
    }
    if (pipeline.state) |state| {
        release(state);
    }
    pipeline.* = .{};
}

/// Bind the pipeline for rendering
pub fn bind(encoder: ?*anyopaque, pipeline: *const MetalPipeline) void {
    const enc = encoder orelse return;

    if (pipeline.state) |state| {
        _ = msg1(void, enc, sel("setRenderPipelineState:"), state);
    }
    if (pipeline.depth_stencil_state) |state| {
        _ = msg1(void, enc, sel("setDepthStencilState:"), state);
    }
}

/// Push constants to the encoder (model matrix)
pub fn pushConstants(encoder: ?*anyopaque, push_constant: *const PushConstantObject) void {
    const enc = encoder orelse return;

    // Set vertex bytes at buffer index 0 (matching Vertex MSL: [[buffer(0)]])
    // Using setVertexBytes:length:atIndex:
    _ = msg3(
        void,
        enc,
        sel("setVertexBytes:length:atIndex:"),
        push_constant,
        @as(u64, @sizeOf(PushConstantObject)),
        @as(u64, 0), // Buffer index 0 for push constants
    );
}

/// Check if pipeline is valid
pub fn isValid(pipeline: *const MetalPipeline) bool {
    return pipeline.state != null;
}

/// Create grid pipeline (simplified vertex format - only position)
pub fn createGridPipeline(
    context: *MetalContext,
    vertex_function: metal_context.MTLFunction,
    fragment_function: metal_context.MTLFunction,
    pipeline: *MetalPipeline,
) bool {
    const device = context.device orelse {
        logger.err("Cannot create grid pipeline: no Metal device", .{});
        return false;
    };

    logger.debug("Creating grid shader pipeline...", .{});

    // Create render pipeline descriptor
    const desc_class = getClass("MTLRenderPipelineDescriptor") orelse {
        logger.err("Failed to get MTLRenderPipelineDescriptor class", .{});
        return false;
    };

    const desc_alloc = msg(?*anyopaque, desc_class, sel("alloc"));
    if (desc_alloc == null) return false;

    const desc = msg(?*anyopaque, desc_alloc, sel("init"));
    if (desc == null) return false;

    // Set vertex and fragment functions
    _ = msg1(void, desc, sel("setVertexFunction:"), vertex_function);
    _ = msg1(void, desc, sel("setFragmentFunction:"), fragment_function);

    // Configure color attachment with alpha blending
    const color_attachments = msg(?*anyopaque, desc, sel("colorAttachments"));
    if (color_attachments) |attachments| {
        const attachment = msg1(?*anyopaque, attachments, sel("objectAtIndexedSubscript:"), @as(u64, 0));
        if (attachment) |att| {
            // Must match main_color resource format (rgba16_float)
            _ = msg1(void, att, sel("setPixelFormat:"), @as(u64, metal_context.MTLPixelFormat.RGBA16Float));

            // Enable blending for grid transparency
            _ = msg1(void, att, sel("setBlendingEnabled:"), @as(i8, 1));
            _ = msg1(void, att, sel("setSourceRGBBlendFactor:"), @as(u64, 4)); // MTLBlendFactorSourceAlpha
            _ = msg1(void, att, sel("setDestinationRGBBlendFactor:"), @as(u64, 5)); // MTLBlendFactorOneMinusSourceAlpha
            _ = msg1(void, att, sel("setRgbBlendOperation:"), @as(u64, 0)); // MTLBlendOperationAdd
            _ = msg1(void, att, sel("setSourceAlphaBlendFactor:"), @as(u64, 1)); // MTLBlendFactorOne
            _ = msg1(void, att, sel("setDestinationAlphaBlendFactor:"), @as(u64, 0)); // MTLBlendFactorZero
            _ = msg1(void, att, sel("setAlphaBlendOperation:"), @as(u64, 0)); // MTLBlendOperationAdd
        }
    }

    // Set depth attachment format
    _ = msg1(void, desc, sel("setDepthAttachmentPixelFormat:"), @as(u64, metal_context.MTLPixelFormat.Depth32Float));

    // Configure vertex descriptor for grid (only position - float3)
    const vertex_desc_class = getClass("MTLVertexDescriptor") orelse {
        logger.err("Failed to get MTLVertexDescriptor class", .{});
        release(desc);
        return false;
    };

    const vertex_desc_alloc = msg(?*anyopaque, vertex_desc_class, sel("alloc"));
    const vertex_desc = msg(?*anyopaque, vertex_desc_alloc, sel("init"));
    if (vertex_desc == null) {
        release(desc);
        return false;
    }

    // Position attribute (location 0)
    // Use buffer index 30 to avoid conflict with Camera uniform at buffer(0)
    const attributes = msg(?*anyopaque, vertex_desc, sel("attributes"));
    if (attributes) |attrs| {
        const pos_attr = msg1(?*anyopaque, attrs, sel("objectAtIndexedSubscript:"), @as(u64, 0));
        if (pos_attr) |attr| {
            _ = msg1(void, attr, sel("setFormat:"), @as(u64, metal_context.MTLVertexFormat.Float3));
            _ = msg1(void, attr, sel("setOffset:"), @as(u64, 0));
            _ = msg1(void, attr, sel("setBufferIndex:"), @as(u64, 30));
        }
    }

    // Layout for buffer 30 (vertex buffer)
    const layouts = msg(?*anyopaque, vertex_desc, sel("layouts"));
    if (layouts) |lyt| {
        const buffer_layout = msg1(?*anyopaque, lyt, sel("objectAtIndexedSubscript:"), @as(u64, 30));
        if (buffer_layout) |layout| {
            _ = msg1(void, layout, sel("setStride:"), @as(u64, @sizeOf([3]f32)));
            _ = msg1(void, layout, sel("setStepFunction:"), @as(u64, metal_context.MTLVertexStepFunction.PerVertex));
        }
    }

    _ = msg1(void, desc, sel("setVertexDescriptor:"), vertex_desc);

    // Create pipeline state
    var error_ptr: ?*anyopaque = null;
    const pipeline_state = msg2(
        ?*anyopaque,
        device,
        sel("newRenderPipelineStateWithDescriptor:error:"),
        desc,
        &error_ptr,
    );

    release(vertex_desc);
    release(desc);

    if (pipeline_state == null) {
        if (error_ptr) |err| {
            const err_desc = msg(?*anyopaque, err, sel("localizedDescription"));
            if (err_desc) |d| {
                const c_str = msg([*:0]const u8, d, sel("UTF8String"));
                logger.err("Grid pipeline creation failed: {s}", .{c_str});
            }
        } else {
            logger.err("Grid pipeline creation failed: unknown error", .{});
        }
        return false;
    }

    // Create depth stencil state (depth test enabled, depth write disabled)
    const depth_stencil_state = createGridDepthStencilState(device) orelse {
        logger.err("Failed to create grid depth stencil state", .{});
        release(pipeline_state);
        return false;
    };

    logger.info("Grid shader pipeline created.", .{});

    pipeline.* = MetalPipeline{
        .state = pipeline_state,
        .depth_stencil_state = depth_stencil_state,
    };

    return true;
}

/// Create depth stencil state for grid (depth test enabled, write disabled)
fn createGridDepthStencilState(device: ?*anyopaque) ?*anyopaque {
    const desc_class = getClass("MTLDepthStencilDescriptor") orelse return null;
    const desc_alloc = msg(?*anyopaque, desc_class, sel("alloc"));
    if (desc_alloc == null) return null;

    const desc = msg(?*anyopaque, desc_alloc, sel("init"));
    if (desc == null) return null;

    // Enable depth test but disable depth write
    _ = msg1(void, desc, sel("setDepthCompareFunction:"), @as(u64, metal_context.MTLCompareFunction.LessEqual));
    _ = msg1(void, desc, sel("setDepthWriteEnabled:"), @as(i8, 0)); // No depth write

    const depth_stencil_state = msg1(?*anyopaque, device, sel("newDepthStencilStateWithDescriptor:"), desc);

    release(desc);

    return depth_stencil_state;
}
