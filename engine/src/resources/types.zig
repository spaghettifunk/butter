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
    TEXTURE_USE_MAP_DIFFUSE = 0x01, // Legacy - mapped to ALBEDO
    TEXTURE_USE_MAP_SPECULAR = 0x02, // Legacy - mapped to METALLIC_ROUGHNESS
    // PBR texture types
    TEXTURE_USE_MAP_ALBEDO = 0x03,
    TEXTURE_USE_MAP_METALLIC_ROUGHNESS = 0x04, // Packed: R=unused, G=roughness, B=metallic
    TEXTURE_USE_MAP_NORMAL = 0x05,
    TEXTURE_USE_MAP_AO = 0x06,
    TEXTURE_USE_MAP_EMISSIVE = 0x07,
    TEXTURE_USE_MAP_IRRADIANCE = 0x08, // Cubemap for IBL
    TEXTURE_USE_MAP_PREFILTERED = 0x09, // Cubemap for IBL
    TEXTURE_USE_MAP_BRDF_LUT = 0x0A,
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

    // PBR material properties
    base_color: math_types.Vec4 = .{ .elements = .{ 1.0, 1.0, 1.0, 1.0 } },
    roughness: f32 = 0.8,
    metallic: f32 = 0.0,
    emissive_strength: f32 = 0.0,

    // PBR texture maps
    albedo_map: TextureMap,
    metallic_roughness_map: TextureMap,
    normal_map: TextureMap,
    ao_map: TextureMap,
    emissive_map: TextureMap,

    // Legacy support (for backward compatibility)
    diffuse_colour: math_types.Vec4 = .{ .elements = .{ 1.0, 1.0, 1.0, 1.0 } }, // Alias for base_color
    diffuse_map: TextureMap, // Alias for albedo_map
    specular_map: TextureMap, // Alias for metallic_roughness_map
    specular_color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    shininess: f32 = 32.0,

    /// Backend-specific descriptor set (Vulkan: VkDescriptorSet, Metal: null)
    /// Used for per-material texture binding in the two-tier descriptor architecture
    descriptor_set: ?*anyopaque = null,
};
