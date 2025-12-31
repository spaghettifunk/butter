//! Metal context - holds all Metal-specific state.

const std = @import("std");

const objc = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

/// Opaque pointer types for Metal objects
pub const MTLDevice = ?*anyopaque;
pub const MTLCommandQueue = ?*anyopaque;
pub const MTLCommandBuffer = ?*anyopaque;
pub const MTLRenderCommandEncoder = ?*anyopaque;
pub const CAMetalLayer = ?*anyopaque;
pub const CAMetalDrawable = ?*anyopaque;
pub const MTLRenderPipelineState = ?*anyopaque;
pub const MTLDepthStencilState = ?*anyopaque;
pub const MTLLibrary = ?*anyopaque;
pub const MTLFunction = ?*anyopaque;
pub const MTLBuffer = ?*anyopaque;
pub const MTLTexture = ?*anyopaque;
pub const MTLSamplerState = ?*anyopaque;
pub const MTLRenderPassDescriptor = ?*anyopaque;
pub const NSError = ?*anyopaque;

/// SEL type alias
pub const SEL = objc.SEL;

/// CGSize struct for drawable dimensions
pub const CGSize = extern struct {
    width: f64,
    height: f64,
};

/// MTLViewport struct
pub const MTLViewport = extern struct {
    originX: f64,
    originY: f64,
    width: f64,
    height: f64,
    znear: f64,
    zfar: f64,
};

/// MTLScissorRect struct
pub const MTLScissorRect = extern struct {
    x: u64,
    y: u64,
    width: u64,
    height: u64,
};

/// MTLClearColor struct
pub const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

/// MTLRegion struct for texture operations
pub const MTLRegion = extern struct {
    origin: MTLOrigin,
    size: MTLSize,
};

pub const MTLOrigin = extern struct {
    x: u64,
    y: u64,
    z: u64,
};

pub const MTLSize = extern struct {
    width: u64,
    height: u64,
    depth: u64,
};

/// MTLPixelFormat enum values we use
pub const MTLPixelFormat = struct {
    pub const BGRA8Unorm: u64 = 80;
    pub const BGRA8Unorm_sRGB: u64 = 81; // sRGB version for gamma-correct rendering
    pub const RGBA8Unorm: u64 = 70;
    pub const RGBA8Unorm_sRGB: u64 = 71; // sRGB version
    pub const R8Unorm: u64 = 10;
    pub const RG8Unorm: u64 = 30;
    pub const Depth32Float: u64 = 252;
    pub const Invalid: u64 = 0;
};

/// MTLLoadAction enum values
pub const MTLLoadAction = struct {
    pub const DontCare: u64 = 0;
    pub const Load: u64 = 1;
    pub const Clear: u64 = 2;
};

/// MTLStoreAction enum values
pub const MTLStoreAction = struct {
    pub const DontCare: u64 = 0;
    pub const Store: u64 = 1;
};

/// MTLPrimitiveType enum values
pub const MTLPrimitiveType = struct {
    pub const Point: u64 = 0;
    pub const Line: u64 = 1;
    pub const LineStrip: u64 = 2;
    pub const Triangle: u64 = 3;
    pub const TriangleStrip: u64 = 4;
};

/// MTLIndexType enum values
pub const MTLIndexType = struct {
    pub const UInt16: u64 = 0;
    pub const UInt32: u64 = 1;
};

/// MTLResourceOptions for buffer creation
pub const MTLResourceOptions = struct {
    pub const StorageModeShared: u64 = 0;
    pub const StorageModeManaged: u64 = 1 << 4;
    pub const StorageModePrivate: u64 = 2 << 4;
    pub const CPUCacheModeDefaultCache: u64 = 0;
    pub const CPUCacheModeWriteCombined: u64 = 1;
};

/// MTLTextureUsage flags
pub const MTLTextureUsage = struct {
    pub const Unknown: u64 = 0;
    pub const ShaderRead: u64 = 1;
    pub const ShaderWrite: u64 = 2;
    pub const RenderTarget: u64 = 4;
    pub const PixelFormatView: u64 = 16;
};

/// MTLCompareFunction for depth testing
pub const MTLCompareFunction = struct {
    pub const Never: u64 = 0;
    pub const Less: u64 = 1;
    pub const Equal: u64 = 2;
    pub const LessEqual: u64 = 3;
    pub const Greater: u64 = 4;
    pub const NotEqual: u64 = 5;
    pub const GreaterEqual: u64 = 6;
    pub const Always: u64 = 7;
};

/// MTLVertexFormat enum values
pub const MTLVertexFormat = struct {
    pub const Invalid: u64 = 0;
    pub const Float: u64 = 28;
    pub const Float2: u64 = 29;
    pub const Float3: u64 = 30;
    pub const Float4: u64 = 31;
};

/// MTLVertexStepFunction enum values
pub const MTLVertexStepFunction = struct {
    pub const Constant: u64 = 0;
    pub const PerVertex: u64 = 1;
    pub const PerInstance: u64 = 2;
};

/// MTLSamplerMinMagFilter
pub const MTLSamplerMinMagFilter = struct {
    pub const Nearest: u64 = 0;
    pub const Linear: u64 = 1;
};

/// MTLSamplerAddressMode
pub const MTLSamplerAddressMode = struct {
    pub const ClampToEdge: u64 = 0;
    pub const Repeat: u64 = 2;
    pub const MirrorRepeat: u64 = 3;
    pub const ClampToZero: u64 = 4;
};

/// MTLCullMode
pub const MTLCullMode = struct {
    pub const None: u64 = 0;
    pub const Front: u64 = 1;
    pub const Back: u64 = 2;
};

/// MTLWinding
pub const MTLWinding = struct {
    pub const Clockwise: u64 = 0;
    pub const CounterClockwise: u64 = 1;
};

/// Maximum frames in flight (matching Vulkan)
pub const MAX_FRAMES_IN_FLIGHT: u32 = 2;

/// Metal context holding all state
pub const MetalContext = struct {
    // Core objects
    device: MTLDevice = null,
    command_queue: MTLCommandQueue = null,
    layer: CAMetalLayer = null,

    // Current frame state (set during beginFrame, cleared in endFrame)
    current_drawable: CAMetalDrawable = null,
    current_command_buffer: MTLCommandBuffer = null,
    current_render_encoder: MTLRenderCommandEncoder = null,

    // Depth buffer
    depth_texture: MTLTexture = null,

    // Frame tracking for double-buffering
    frame_index: u32 = 0,

    // Framebuffer dimensions
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,
};

// ============================================================================
// Objective-C Runtime Helpers
// ============================================================================

/// Get an Objective-C class by name
pub fn objc_getClass(name: [*:0]const u8) ?*anyopaque {
    return @ptrCast(objc.objc_getClass(name));
}

/// Register a selector by name
pub fn sel_registerName(name: [*:0]const u8) SEL {
    return objc.sel_registerName(name);
}

/// Message send with no arguments
pub fn msgSend(comptime ReturnType: type, target: anytype, sel: SEL) ReturnType {
    const TargetType = @TypeOf(target);
    const MsgSendFn = *const fn (TargetType, SEL) callconv(.c) ReturnType;
    const func: MsgSendFn = @ptrCast(&objc.objc_msgSend);
    return func(target, sel);
}

/// Message send with 1 argument
pub fn msgSend1(comptime ReturnType: type, target: anytype, sel: SEL, arg1: anytype) ReturnType {
    const TargetType = @TypeOf(target);
    const Arg1Type = @TypeOf(arg1);
    const MsgSendFn = *const fn (TargetType, SEL, Arg1Type) callconv(.c) ReturnType;
    const func: MsgSendFn = @ptrCast(&objc.objc_msgSend);
    return func(target, sel, arg1);
}

/// Message send with 2 arguments
pub fn msgSend2(comptime ReturnType: type, target: anytype, sel: SEL, arg1: anytype, arg2: anytype) ReturnType {
    const TargetType = @TypeOf(target);
    const Arg1Type = @TypeOf(arg1);
    const Arg2Type = @TypeOf(arg2);
    const MsgSendFn = *const fn (TargetType, SEL, Arg1Type, Arg2Type) callconv(.c) ReturnType;
    const func: MsgSendFn = @ptrCast(&objc.objc_msgSend);
    return func(target, sel, arg1, arg2);
}

/// Message send with 3 arguments
pub fn msgSend3(comptime ReturnType: type, target: anytype, sel: SEL, arg1: anytype, arg2: anytype, arg3: anytype) ReturnType {
    const TargetType = @TypeOf(target);
    const Arg1Type = @TypeOf(arg1);
    const Arg2Type = @TypeOf(arg2);
    const Arg3Type = @TypeOf(arg3);
    const MsgSendFn = *const fn (TargetType, SEL, Arg1Type, Arg2Type, Arg3Type) callconv(.c) ReturnType;
    const func: MsgSendFn = @ptrCast(&objc.objc_msgSend);
    return func(target, sel, arg1, arg2, arg3);
}

/// Message send with 4 arguments
pub fn msgSend4(comptime ReturnType: type, target: anytype, sel: SEL, arg1: anytype, arg2: anytype, arg3: anytype, arg4: anytype) ReturnType {
    const TargetType = @TypeOf(target);
    const Arg1Type = @TypeOf(arg1);
    const Arg2Type = @TypeOf(arg2);
    const Arg3Type = @TypeOf(arg3);
    const Arg4Type = @TypeOf(arg4);
    const MsgSendFn = *const fn (TargetType, SEL, Arg1Type, Arg2Type, Arg3Type, Arg4Type) callconv(.c) ReturnType;
    const func: MsgSendFn = @ptrCast(&objc.objc_msgSend);
    return func(target, sel, arg1, arg2, arg3, arg4);
}

/// Message send with 5 arguments
pub fn msgSend5(comptime ReturnType: type, target: anytype, sel: SEL, arg1: anytype, arg2: anytype, arg3: anytype, arg4: anytype, arg5: anytype) ReturnType {
    const TargetType = @TypeOf(target);
    const Arg1Type = @TypeOf(arg1);
    const Arg2Type = @TypeOf(arg2);
    const Arg3Type = @TypeOf(arg3);
    const Arg4Type = @TypeOf(arg4);
    const Arg5Type = @TypeOf(arg5);
    const MsgSendFn = *const fn (TargetType, SEL, Arg1Type, Arg2Type, Arg3Type, Arg4Type, Arg5Type) callconv(.c) ReturnType;
    const func: MsgSendFn = @ptrCast(&objc.objc_msgSend);
    return func(target, sel, arg1, arg2, arg3, arg4, arg5);
}

// Legacy alias for compatibility with existing code
pub fn msgSendSuper(comptime ReturnType: type, target: anytype, sel: SEL, arg: anytype) ReturnType {
    return msgSend1(ReturnType, target, sel, arg);
}

/// Create a helper for common patterns - release an object
pub fn release(obj: anytype) void {
    if (@as(?*anyopaque, obj)) |ptr| {
        const sel = sel_registerName("release");
        _ = msgSend(void, ptr, sel);
    }
}

/// Retain an object
pub fn retain(obj: anytype) @TypeOf(obj) {
    if (@as(?*anyopaque, obj)) |ptr| {
        const sel = sel_registerName("retain");
        _ = msgSend(?*anyopaque, ptr, sel);
    }
    return obj;
}

/// Autorelease an object
pub fn autorelease(obj: anytype) @TypeOf(obj) {
    if (@as(?*anyopaque, obj)) |ptr| {
        const sel = sel_registerName("autorelease");
        _ = msgSend(?*anyopaque, ptr, sel);
    }
    return obj;
}
