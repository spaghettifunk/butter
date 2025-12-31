//! Render Graph Resource System
//!
//! Provides type-safe, generation-counted handles for render resources and
//! descriptors for creating textures and buffers used in the render graph.

const std = @import("std");

/// Generation-counted handle for render resources.
/// Uses generation counting to detect stale handles after resource destruction.
pub const ResourceHandle = struct {
    index: u16,
    generation: u16,

    pub const invalid = ResourceHandle{ .index = 0xFFFF, .generation = 0 };

    pub fn isValid(self: ResourceHandle) bool {
        return self.index != 0xFFFF;
    }

    pub fn eql(self: ResourceHandle, other: ResourceHandle) bool {
        return self.index == other.index and self.generation == other.generation;
    }
};

/// Resource type enumeration
pub const ResourceType = enum(u8) {
    texture_2d,
    texture_cube,
    depth_buffer,
    buffer_uniform,
    buffer_storage,
    buffer_vertex,
    buffer_index,
    acceleration_structure, // Future raytracing support
};

/// Texture format abstraction (maps to VkFormat/MTLPixelFormat)
pub const TextureFormat = enum(u8) {
    // Color formats
    rgba8_unorm,
    rgba8_srgb,
    bgra8_unorm,
    bgra8_srgb,
    rgba16_float,
    rgba32_float,
    rg16_float,
    rg32_float,
    r16_float,
    r32_float,
    r8_unorm,

    // Depth formats
    depth32_float,
    depth24_stencil8,
    depth16_unorm,

    /// Convert to Vulkan VkFormat
    pub fn toVulkan(self: TextureFormat) u32 {
        return switch (self) {
            .rgba8_unorm => 37, // VK_FORMAT_R8G8B8A8_UNORM
            .rgba8_srgb => 43, // VK_FORMAT_R8G8B8A8_SRGB
            .bgra8_unorm => 44, // VK_FORMAT_B8G8R8A8_UNORM
            .bgra8_srgb => 50, // VK_FORMAT_B8G8R8A8_SRGB
            .rgba16_float => 97, // VK_FORMAT_R16G16B16A16_SFLOAT
            .rgba32_float => 109, // VK_FORMAT_R32G32B32A32_SFLOAT
            .rg16_float => 83, // VK_FORMAT_R16G16_SFLOAT
            .rg32_float => 103, // VK_FORMAT_R32G32_SFLOAT
            .r16_float => 76, // VK_FORMAT_R16_SFLOAT
            .r32_float => 100, // VK_FORMAT_R32_SFLOAT
            .r8_unorm => 9, // VK_FORMAT_R8_UNORM
            .depth32_float => 126, // VK_FORMAT_D32_SFLOAT
            .depth24_stencil8 => 129, // VK_FORMAT_D24_UNORM_S8_UINT
            .depth16_unorm => 124, // VK_FORMAT_D16_UNORM
        };
    }

    /// Convert to Metal MTLPixelFormat
    pub fn toMetal(self: TextureFormat) u64 {
        return switch (self) {
            .rgba8_unorm => 70, // MTLPixelFormatRGBA8Unorm
            .rgba8_srgb => 71, // MTLPixelFormatRGBA8Unorm_sRGB
            .bgra8_unorm => 80, // MTLPixelFormatBGRA8Unorm
            .bgra8_srgb => 81, // MTLPixelFormatBGRA8Unorm_sRGB
            .rgba16_float => 115, // MTLPixelFormatRGBA16Float
            .rgba32_float => 125, // MTLPixelFormatRGBA32Float
            .rg16_float => 111, // MTLPixelFormatRG16Float
            .rg32_float => 123, // MTLPixelFormatRG32Float
            .r16_float => 108, // MTLPixelFormatR16Float
            .r32_float => 120, // MTLPixelFormatR32Float
            .r8_unorm => 10, // MTLPixelFormatR8Unorm
            .depth32_float => 252, // MTLPixelFormatDepth32Float
            .depth24_stencil8 => 255, // MTLPixelFormatDepth24Unorm_Stencil8
            .depth16_unorm => 250, // MTLPixelFormatDepth16Unorm
        };
    }

    /// Check if this is a depth format
    pub fn isDepthFormat(self: TextureFormat) bool {
        return switch (self) {
            .depth32_float, .depth24_stencil8, .depth16_unorm => true,
            else => false,
        };
    }

    /// Check if this format has a stencil component
    pub fn hasStencil(self: TextureFormat) bool {
        return self == .depth24_stencil8;
    }

    /// Get bytes per pixel for this format
    pub fn bytesPerPixel(self: TextureFormat) u8 {
        return switch (self) {
            .r8_unorm => 1,
            .r16_float, .depth16_unorm => 2,
            .rgba8_unorm, .rgba8_srgb, .bgra8_unorm, .bgra8_srgb => 4,
            .r32_float, .rg16_float, .depth32_float, .depth24_stencil8 => 4,
            .rgba16_float, .rg32_float => 8,
            .rgba32_float => 16,
        };
    }
};

/// Resource usage flags - describes how a resource will be used
pub const ResourceUsage = packed struct(u8) {
    color_attachment: bool = false,
    depth_attachment: bool = false,
    sampled: bool = false,
    storage: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    _padding: u2 = 0,

    pub const none = ResourceUsage{};

    pub const render_target = ResourceUsage{
        .color_attachment = true,
        .sampled = true,
    };

    pub const depth_target = ResourceUsage{
        .depth_attachment = true,
    };

    pub const depth_target_sampled = ResourceUsage{
        .depth_attachment = true,
        .sampled = true,
    };

    pub const sampled_texture = ResourceUsage{
        .sampled = true,
        .transfer_dst = true,
    };

    pub const storage_texture = ResourceUsage{
        .storage = true,
        .sampled = true,
    };
};

/// Texture descriptor for resource creation
pub const TextureDesc = struct {
    width: u32,
    height: u32,
    depth: u32 = 1,
    mip_levels: u8 = 1,
    array_layers: u8 = 1,
    format: TextureFormat,
    usage: ResourceUsage,
    samples: u8 = 1,
    is_transient: bool = true, // Transient resources can be aliased in memory

    /// Calculate total size in bytes (without mips)
    pub fn sizeInBytes(self: TextureDesc) usize {
        return @as(usize, self.width) * @as(usize, self.height) *
            @as(usize, self.depth) * @as(usize, self.format.bytesPerPixel());
    }
};

/// Buffer descriptor for resource creation
pub const BufferDesc = struct {
    size: usize,
    usage: ResourceUsage,
    is_transient: bool = false,
};

/// Resource descriptor union - describes any type of render graph resource
pub const ResourceDesc = union(ResourceType) {
    texture_2d: TextureDesc,
    texture_cube: TextureDesc,
    depth_buffer: TextureDesc,
    buffer_uniform: BufferDesc,
    buffer_storage: BufferDesc,
    buffer_vertex: BufferDesc,
    buffer_index: BufferDesc,
    acceleration_structure: void, // Stub for future raytracing

    /// Get the texture descriptor if this is a texture resource
    pub fn getTextureDesc(self: ResourceDesc) ?TextureDesc {
        return switch (self) {
            .texture_2d, .texture_cube, .depth_buffer => |desc| desc,
            else => null,
        };
    }

    /// Get the buffer descriptor if this is a buffer resource
    pub fn getBufferDesc(self: ResourceDesc) ?BufferDesc {
        return switch (self) {
            .buffer_uniform, .buffer_storage, .buffer_vertex, .buffer_index => |desc| desc,
            else => null,
        };
    }

    /// Check if this resource is transient (can be aliased)
    pub fn isTransient(self: ResourceDesc) bool {
        return switch (self) {
            .texture_2d, .texture_cube, .depth_buffer => |desc| desc.is_transient,
            .buffer_uniform, .buffer_storage, .buffer_vertex, .buffer_index => |desc| desc.is_transient,
            .acceleration_structure => false,
        };
    }

    /// Get resource type
    pub fn getType(self: ResourceDesc) ResourceType {
        return self;
    }
};

/// Resource dimension for size calculations
pub const ResourceDimension = enum {
    d1d,
    d2d,
    d3d,
    cube,
};

test "ResourceHandle validity" {
    const valid = ResourceHandle{ .index = 0, .generation = 1 };
    const invalid = ResourceHandle.invalid;

    try std.testing.expect(valid.isValid());
    try std.testing.expect(!invalid.isValid());
}

test "TextureFormat properties" {
    try std.testing.expect(TextureFormat.depth32_float.isDepthFormat());
    try std.testing.expect(!TextureFormat.rgba8_unorm.isDepthFormat());
    try std.testing.expect(TextureFormat.depth24_stencil8.hasStencil());
    try std.testing.expectEqual(@as(u8, 4), TextureFormat.rgba8_unorm.bytesPerPixel());
}
