const math_types = @import("../math/types.zig");

pub const TEXTURE_NAME_MAX_LENGTH: u32 = 512;

pub const Texture = struct {
    id: u32,
    width: u32,
    height: u32,
    channel_count: u8,
    has_transparency: bool,
    generation: u32,
    internal_data: ?*anyopaque,
};

pub const TextureUse = enum(u16) {
    TEXTURE_USE_UNKNOWN = 0x00,
    TEXTURE_USE_MAP_DIFFUSE = 0x01,
    TEXTURE_USE_MAP_SPECULAR = 0x02,
};

pub const TextureMap = struct {
    texture: *Texture,
    use: TextureUse,
};

pub const MATERIAL_NAME_MAX_LENGTH: u32 = 256;

pub const Material = struct {
    id: u32,
    generation: u32,
    internal_id: u32,
    name: [MATERIAL_NAME_MAX_LENGTH]u8,
    diffuse_colour: math_types.Vec4,
    diffuse_map: TextureMap,
    specular_map: TextureMap,
    specular_color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    shininess: f32 = 32.0,

    /// Backend-specific descriptor set (Vulkan: VkDescriptorSet, Metal: null)
    /// Used for per-material texture binding in the two-tier descriptor architecture
    descriptor_set: ?*anyopaque = null,
};
