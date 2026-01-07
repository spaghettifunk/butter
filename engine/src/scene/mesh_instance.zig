//! MeshInstance - Scene entity representing a placed mesh in the world.
//!
//! Provides:
//! - Reference to MeshAsset (shared GPU geometry)
//! - World transform (position/rotation/scale)
//! - Material bindings (per submesh)
//! - Optional per-instance data (ID, flags)
//!
//! Design:
//! - MeshInstance is cheap to create/destroy (no geometry duplication)
//! - Multiple instances can reference the same MeshAsset
//! - Each instance can have different materials/transforms
//! - Instance data can be used for GPU instancing, picking, etc.

const std = @import("std");
const handle = @import("../resources/handle.zig");
const mesh_asset_types = @import("../resources/mesh_asset_types.zig");
const math_types = @import("../math/types.zig");

const MAX_SUBMESHES = mesh_asset_types.MAX_SUBMESHES;

// Resource handles
pub const MeshAssetHandle = handle.MeshAssetHandle;
pub const MaterialHandle = handle.MaterialHandle;

// ============================================================================
// MeshInstance
// ============================================================================

/// MeshInstance - Represents a mesh placed in the scene
///
/// This structure connects a MeshAsset (shared GPU geometry) to the scene graph.
/// It stores the world transform, material bindings, and optional instance data.
///
/// Example usage:
/// ```zig
/// var instance = MeshInstance{
///     .mesh_handle = mesh_handle,
///     .transform = math.mat4Translation(.{0, 1, 0}),
/// };
/// instance.setMaterial(0, diffuse_material);
/// instance.setMaterial(1, glass_material);
/// ```
pub const MeshInstance = struct {
    /// Handle to the MeshAsset containing geometry data
    mesh_handle: MeshAssetHandle,

    /// World transform matrix (position, rotation, scale)
    /// This is the model matrix used for rendering
    transform: math_types.Mat4 = math_types.mat4Identity(),

    /// Material bindings (one per submesh)
    /// The array size matches MAX_SUBMESHES (32)
    /// Use material_count to determine how many are valid
    materials: [MAX_SUBMESHES]MaterialHandle = [_]MaterialHandle{.{ .id = 0, .generation = 0 }} ** MAX_SUBMESHES,

    /// Number of valid materials (should match MeshAsset.submesh_count)
    material_count: u8 = 0,

    /// Optional instance ID (for GPU instancing, picking, etc.)
    /// Can be used to identify this instance in shaders or for selection
    instance_id: u32 = 0,

    /// Optional instance flags (bitfield for various states)
    /// Examples: visible, cast_shadows, receive_shadows, etc.
    flags: u32 = 0,

    // ========================================================================
    // Material Management
    // ========================================================================

    /// Set the material for a specific submesh
    ///
    /// The submesh_index must be less than material_count.
    /// This updates the material handle and expands material_count if needed.
    pub fn setMaterial(self: *MeshInstance, submesh_index: u8, material_handle: MaterialHandle) void {
        if (submesh_index >= MAX_SUBMESHES) return;

        self.materials[submesh_index] = material_handle;

        // Update material count if this index is beyond current count
        if (submesh_index >= self.material_count) {
            self.material_count = submesh_index + 1;
        }
    }

    /// Get the material handle for a specific submesh
    ///
    /// Returns null if the submesh_index is out of bounds.
    pub fn getMaterial(self: *const MeshInstance, submesh_index: u8) ?MaterialHandle {
        if (submesh_index >= self.material_count) return null;
        return self.materials[submesh_index];
    }

    /// Set all materials to the same handle (useful for single-material meshes)
    pub fn setAllMaterials(self: *MeshInstance, material_handle: MaterialHandle, count: u8) void {
        const actual_count = @min(count, MAX_SUBMESHES);
        for (0..actual_count) |i| {
            self.materials[i] = material_handle;
        }
        self.material_count = actual_count;
    }

    // ========================================================================
    // Transform Helpers
    // ========================================================================

    /// Set the world position (translation only, preserves rotation/scale)
    pub fn setPosition(self: *MeshInstance, position: math_types.Vec3) void {
        self.transform.data[12] = position.x();
        self.transform.data[13] = position.y();
        self.transform.data[14] = position.z();
    }

    /// Get the world position from the transform matrix
    pub fn getPosition(self: *const MeshInstance) math_types.Vec3 {
        return math_types.Vec3.new(
            self.transform.data[12],
            self.transform.data[13],
            self.transform.data[14],
        );
    }

    // ========================================================================
    // Flags
    // ========================================================================

    /// Flag bits for common instance states
    pub const Flags = struct {
        pub const VISIBLE: u32 = 1 << 0;
        pub const CAST_SHADOWS: u32 = 1 << 1;
        pub const RECEIVE_SHADOWS: u32 = 1 << 2;
        pub const FRUSTUM_CULLED: u32 = 1 << 3;
        pub const STATIC: u32 = 1 << 4;
    };

    /// Check if a flag is set
    pub fn hasFlag(self: *const MeshInstance, flag: u32) bool {
        return (self.flags & flag) != 0;
    }

    /// Set a flag
    pub fn setFlag(self: *MeshInstance, flag: u32) void {
        self.flags |= flag;
    }

    /// Clear a flag
    pub fn clearFlag(self: *MeshInstance, flag: u32) void {
        self.flags &= ~flag;
    }

    /// Toggle a flag
    pub fn toggleFlag(self: *MeshInstance, flag: u32) void {
        self.flags ^= flag;
    }

    // ========================================================================
    // Utility
    // ========================================================================

    /// Check if the instance is visible (convenience wrapper)
    pub fn isVisible(self: *const MeshInstance) bool {
        return self.hasFlag(Flags.VISIBLE);
    }

    /// Set visibility (convenience wrapper)
    pub fn setVisible(self: *MeshInstance, visible: bool) void {
        if (visible) {
            self.setFlag(Flags.VISIBLE);
        } else {
            self.clearFlag(Flags.VISIBLE);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "MeshInstance: material management" {
    var instance = MeshInstance{
        .mesh_handle = .{ .id = 1, .generation = 0 },
    };

    // Set materials
    const mat0 = MaterialHandle{ .id = 10, .generation = 0 };
    const mat1 = MaterialHandle{ .id = 20, .generation = 0 };

    instance.setMaterial(0, mat0);
    instance.setMaterial(1, mat1);

    try testing.expectEqual(@as(u8, 2), instance.material_count);

    // Get materials
    const retrieved_mat0 = instance.getMaterial(0);
    try testing.expect(retrieved_mat0 != null);
    try testing.expectEqual(mat0.id, retrieved_mat0.?.id);

    // Out of bounds
    const invalid = instance.getMaterial(5);
    try testing.expect(invalid == null);
}

test "MeshInstance: set all materials" {
    var instance = MeshInstance{
        .mesh_handle = .{ .id = 1, .generation = 0 },
    };

    const mat = MaterialHandle{ .id = 100, .generation = 0 };
    instance.setAllMaterials(mat, 3);

    try testing.expectEqual(@as(u8, 3), instance.material_count);

    for (0..3) |i| {
        const retrieved = instance.getMaterial(@intCast(i));
        try testing.expect(retrieved != null);
        try testing.expectEqual(mat.id, retrieved.?.id);
    }
}

test "MeshInstance: flags" {
    var instance = MeshInstance{
        .mesh_handle = .{ .id = 1, .generation = 0 },
    };

    // Initially no flags
    try testing.expect(!instance.hasFlag(MeshInstance.Flags.VISIBLE));

    // Set flag
    instance.setFlag(MeshInstance.Flags.VISIBLE);
    try testing.expect(instance.hasFlag(MeshInstance.Flags.VISIBLE));

    // Clear flag
    instance.clearFlag(MeshInstance.Flags.VISIBLE);
    try testing.expect(!instance.hasFlag(MeshInstance.Flags.VISIBLE));

    // Visibility convenience
    instance.setVisible(true);
    try testing.expect(instance.isVisible());
}

test "MeshInstance: position helpers" {
    var instance = MeshInstance{
        .mesh_handle = .{ .id = 1, .generation = 0 },
    };

    const pos = math_types.Vec3.new(10, 20, 30);
    instance.setPosition(pos);

    const retrieved = instance.getPosition();
    try testing.expectEqual(pos.x(), retrieved.x());
    try testing.expectEqual(pos.y(), retrieved.y());
    try testing.expectEqual(pos.z(), retrieved.z());
}
