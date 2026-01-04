//! Type-safe resource handles with generation counters
//!
//! Resource handles provide:
//! - Type safety (can't mix up texture/material/geometry handles)
//! - Generation counters (detect use-after-free, stale handles)
//! - Small size (8 bytes per handle)
//! - Validation (check if handle is still valid)

const std = @import("std");

/// Generic resource handle with generation counter
pub fn ResourceHandle(comptime T: type) type {
    _ = T; // Type parameter used only for type safety
    return struct {
        id: u32,
        generation: u32,

        const Self = @This();

        /// Invalid handle constant
        pub const invalid = Self{ .id = 0, .generation = 0 };

        /// Check if handle is valid (non-zero ID)
        pub fn isValid(self: Self) bool {
            return self.id != 0;
        }

        /// Compare two handles for equality
        pub fn eql(self: Self, other: Self) bool {
            return self.id == other.id and self.generation == other.generation;
        }

        /// Hash function for use in hash maps
        pub fn hash(self: Self) u64 {
            var h: u64 = self.id;
            h = (h << 32) | self.generation;
            return h;
        }
    };
}

/// Forward declarations for resource types
/// These will be imported from their respective systems
pub const Texture = opaque {};
pub const Material = opaque {};
pub const Geometry = opaque {};
pub const MeshAsset = opaque {};
pub const Font = opaque {};
pub const Scene = opaque {};

/// Concrete handle types for each resource
pub const TextureHandle = ResourceHandle(Texture);
pub const MaterialHandle = ResourceHandle(Material);
pub const GeometryHandle = ResourceHandle(Geometry);
pub const MeshAssetHandle = ResourceHandle(MeshAsset);
pub const FontHandle = ResourceHandle(Font);
pub const SceneHandle = ResourceHandle(Scene);

/// Generic resource type enum for type erasure
pub const ResourceType = enum(u8) {
    texture,
    material,
    geometry,
    mesh_asset,
    shader,
    font,
    scene,
    unknown,

    pub fn toString(self: ResourceType) []const u8 {
        return switch (self) {
            .texture => "texture",
            .material => "material",
            .geometry => "geometry",
            .mesh_asset => "mesh_asset",
            .shader => "shader",
            .font => "font",
            .scene => "scene",
            .unknown => "unknown",
        };
    }
};

/// Type-erased resource handle
pub const AnyResourceHandle = struct {
    id: u32,
    generation: u32,
    resource_type: ResourceType,

    pub fn isValid(self: AnyResourceHandle) bool {
        return self.id != 0;
    }

    pub fn fromTexture(handle: TextureHandle) AnyResourceHandle {
        return .{
            .id = handle.id,
            .generation = handle.generation,
            .resource_type = .texture,
        };
    }

    pub fn fromMaterial(handle: MaterialHandle) AnyResourceHandle {
        return .{
            .id = handle.id,
            .generation = handle.generation,
            .resource_type = .material,
        };
    }

    pub fn fromGeometry(handle: GeometryHandle) AnyResourceHandle {
        return .{
            .id = handle.id,
            .generation = handle.generation,
            .resource_type = .geometry,
        };
    }

    pub fn fromMeshAsset(handle: MeshAssetHandle) AnyResourceHandle {
        return .{
            .id = handle.id,
            .generation = handle.generation,
            .resource_type = .mesh_asset,
        };
    }

    pub fn fromFont(handle: FontHandle) AnyResourceHandle {
        return .{
            .id = handle.id,
            .generation = handle.generation,
            .resource_type = .font,
        };
    }

    pub fn fromScene(handle: SceneHandle) AnyResourceHandle {
        return .{
            .id = handle.id,
            .generation = handle.generation,
            .resource_type = .scene,
        };
    }

    pub fn toTexture(self: AnyResourceHandle) ?TextureHandle {
        if (self.resource_type != .texture) return null;
        return TextureHandle{ .id = self.id, .generation = self.generation };
    }

    pub fn toMaterial(self: AnyResourceHandle) ?MaterialHandle {
        if (self.resource_type != .material) return null;
        return MaterialHandle{ .id = self.id, .generation = self.generation };
    }

    pub fn toGeometry(self: AnyResourceHandle) ?GeometryHandle {
        if (self.resource_type != .geometry) return null;
        return GeometryHandle{ .id = self.id, .generation = self.generation };
    }

    pub fn toMeshAsset(self: AnyResourceHandle) ?MeshAssetHandle {
        if (self.resource_type != .mesh_asset) return null;
        return MeshAssetHandle{ .id = self.id, .generation = self.generation };
    }

    pub fn toFont(self: AnyResourceHandle) ?FontHandle {
        if (self.resource_type != .font) return null;
        return FontHandle{ .id = self.id, .generation = self.generation };
    }

    pub fn toScene(self: AnyResourceHandle) ?SceneHandle {
        if (self.resource_type != .scene) return null;
        return SceneHandle{ .id = self.id, .generation = self.generation };
    }
};

// Tests
const testing = std.testing;

test "ResourceHandle: basic operations" {
    const Handle = ResourceHandle(u32);

    const handle1 = Handle{ .id = 1, .generation = 0 };
    const handle2 = Handle{ .id = 1, .generation = 1 };
    const handle3 = Handle{ .id = 2, .generation = 0 };
    const invalid = Handle.invalid;

    try testing.expect(handle1.isValid());
    try testing.expect(handle2.isValid());
    try testing.expect(handle3.isValid());
    try testing.expect(!invalid.isValid());

    try testing.expect(handle1.eql(handle1));
    try testing.expect(!handle1.eql(handle2)); // Different generation
    try testing.expect(!handle1.eql(handle3)); // Different ID
}

test "AnyResourceHandle: type conversion" {
    const tex_handle = TextureHandle{ .id = 5, .generation = 2 };
    const mat_handle = MaterialHandle{ .id = 10, .generation = 3 };

    const any_tex = AnyResourceHandle.fromTexture(tex_handle);
    _ = AnyResourceHandle.fromMaterial(mat_handle);

    try testing.expect(any_tex.isValid());
    try testing.expectEqual(ResourceType.texture, any_tex.resource_type);
    try testing.expectEqual(@as(u32, 5), any_tex.id);
    try testing.expectEqual(@as(u32, 2), any_tex.generation);

    // Convert back
    const back_to_tex = any_tex.toTexture();
    try testing.expect(back_to_tex != null);
    try testing.expect(back_to_tex.?.eql(tex_handle));

    // Wrong type conversion should fail
    const wrong_mat = any_tex.toMaterial();
    try testing.expect(wrong_mat == null);
}
