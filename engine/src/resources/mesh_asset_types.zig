//! MeshAsset core types - Immutable GPU-resident geometry with submesh support.
//!
//! Provides:
//! - MeshAsset: Immutable mesh resource with one or more submeshes
//! - Submesh: Range-based submesh with precomputed bounds
//! - MeshGpuData: Backend-specific GPU buffer storage (Vulkan/Metal)
//! - IndexType: Index buffer format enumeration
//! - VertexLayout: Vertex format enumeration (currently only Vertex3D)
//!
//! Design principles:
//! - Meshes are immutable after creation (GPU upload)
//! - Submeshes use offsets into parent buffers (no separate allocations)
//! - Materials are NOT stored in MeshAsset (handled by MeshInstance)
//! - Pre-computed bounds enable efficient culling

const std = @import("std");
const renderer = @import("../renderer/renderer.zig");
const vk_buffer = @import("../renderer/vulkan/buffer.zig");
const metal_buffer = @import("../renderer/metal/buffer.zig");
const vk_context = @import("../renderer/vulkan/context.zig");
const vk = vk_context.vk;

// ============================================================================
// Constants
// ============================================================================

/// Maximum number of submeshes per MeshAsset
pub const MAX_SUBMESHES: usize = 32;

/// Maximum length for submesh names
pub const SUBMESH_NAME_MAX_LENGTH: usize = 64;

// ============================================================================
// Enumerations
// ============================================================================

/// Index type enum
pub const IndexType = enum(u8) {
    u16,
    u32,

    /// Get size in bytes
    pub fn getSize(self: IndexType) usize {
        return switch (self) {
            .u16 => 2,
            .u32 => 4,
        };
    }

    /// Convert to Vulkan index type
    pub fn toVulkan(self: IndexType) vk.VkIndexType {
        return switch (self) {
            .u16 => vk.VK_INDEX_TYPE_UINT16,
            .u32 => vk.VK_INDEX_TYPE_UINT32,
        };
    }
};

/// Vertex layout enum - defines the vertex format
/// Currently only Vertex3D is supported, but this allows future expansion
pub const VertexLayout = enum(u8) {
    vertex3d, // 64 bytes: position[3], normal[3], texcoord[2], tangent[4], color[4]

    /// Get vertex size in bytes
    pub fn getSize(self: VertexLayout) usize {
        return switch (self) {
            .vertex3d => 64, // sizeof(Vertex3D)
        };
    }

    /// Get human-readable name
    pub fn toString(self: VertexLayout) []const u8 {
        return switch (self) {
            .vertex3d => "Vertex3D",
        };
    }
};

// ============================================================================
// Submesh
// ============================================================================

/// Submesh - a range within a MeshAsset's vertex/index buffers
///
/// Submeshes allow a single MeshAsset to contain multiple logical parts,
/// each with its own material binding and culling bounds.
///
/// Example: A car mesh might have submeshes for body, windows, wheels, etc.
pub const Submesh = struct {
    /// Submesh name (null-terminated)
    name: [SUBMESH_NAME_MAX_LENGTH]u8 = [_]u8{0} ** SUBMESH_NAME_MAX_LENGTH,

    /// Vertex range (offset into parent MeshAsset's vertex buffer)
    vertex_offset: u32 = 0,
    vertex_count: u32 = 0,

    /// Index range (offset into parent MeshAsset's index buffer)
    /// For non-indexed geometry, index_count will be 0
    index_offset: u32 = 0,
    index_count: u32 = 0,

    /// Precomputed bounding box (AABB) for frustum culling
    bounding_min: [3]f32 = .{ 0, 0, 0 },
    bounding_max: [3]f32 = .{ 0, 0, 0 },

    /// Bounding sphere (center + radius) for fast culling tests
    bounding_center: [3]f32 = .{ 0, 0, 0 },
    bounding_radius: f32 = 0,

    /// Get submesh name as slice (up to null terminator)
    pub fn getName(self: *const Submesh) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    /// Set submesh name (copies up to max length, ensures null termination)
    pub fn setName(self: *Submesh, new_name: []const u8) void {
        const copy_len = @min(new_name.len, SUBMESH_NAME_MAX_LENGTH - 1);
        @memcpy(self.name[0..copy_len], new_name[0..copy_len]);
        self.name[copy_len] = 0;
    }

    /// Check if this is an indexed submesh
    pub fn isIndexed(self: *const Submesh) bool {
        return self.index_count > 0;
    }

    /// Get triangle count (for indexed submeshes)
    pub fn getTriangleCount(self: *const Submesh) u32 {
        if (!self.isIndexed()) return 0;
        return self.index_count / 3;
    }
};

// ============================================================================
// GPU Data
// ============================================================================

/// GPU-side mesh data - supports multiple backends
///
/// This union contains the actual GPU buffer handles for the mesh.
/// The active variant is determined by the renderer backend.
pub const MeshGpuData = union(renderer.BackendType) {
    vulkan: struct {
        vertex_buffer: vk_buffer.VulkanBuffer = .{},
        index_buffer: vk_buffer.VulkanBuffer = .{},
    },
    metal: struct {
        vertex_buffer: metal_buffer.MetalBuffer = .{},
        index_buffer: metal_buffer.MetalBuffer = .{},
    },
    directx: void,
};

// ============================================================================
// MeshAsset
// ============================================================================

/// MeshAsset - Immutable GPU-resident geometry with submesh support
///
/// A MeshAsset represents a complete mesh uploaded to the GPU. It contains:
/// - One or more submeshes (logical parts with different materials)
/// - Vertex and index buffers (shared across all submeshes)
/// - Precomputed bounds for the entire mesh
///
/// MeshAssets are:
/// - Immutable after GPU upload (use MeshBuilder to create new ones)
/// - Reference-counted by the MeshAssetSystem
/// - Shared between multiple MeshInstance objects
///
/// MeshAssets do NOT contain:
/// - Material references (handled by MeshInstance)
/// - Transform data (handled by MeshInstance)
/// - Animation state (handled by separate systems)
pub const MeshAsset = struct {
    /// Resource handle ID (assigned by MeshAssetSystem)
    id: u32 = 0,

    /// Generation counter (for detecting stale handles)
    generation: u32 = 0,

    /// Total vertex count across all submeshes
    vertex_count: u32 = 0,

    /// Total index count across all submeshes (0 for non-indexed meshes)
    index_count: u32 = 0,

    /// Index buffer format
    index_type: IndexType = .u32,

    /// Vertex buffer layout
    vertex_layout: VertexLayout = .vertex3d,

    /// Submeshes (fixed-size array, actual count in submesh_count)
    submeshes: [MAX_SUBMESHES]Submesh = [_]Submesh{.{}} ** MAX_SUBMESHES,

    /// Active submesh count (0 to MAX_SUBMESHES)
    submesh_count: u8 = 0,

    /// Precomputed bounding box for entire mesh (union of all submesh bounds)
    bounding_min: [3]f32 = .{ 0, 0, 0 },
    bounding_max: [3]f32 = .{ 0, 0, 0 },

    /// Bounding sphere for entire mesh
    bounding_center: [3]f32 = .{ 0, 0, 0 },
    bounding_radius: f32 = 0,

    /// Pointer to GPU buffer data (backend-specific)
    /// Null if mesh hasn't been uploaded to GPU yet
    gpu_data: ?*MeshGpuData = null,

    /// Get a submesh by index (returns null if index out of bounds)
    pub fn getSubmesh(self: *const MeshAsset, index: u8) ?*const Submesh {
        if (index >= self.submesh_count) return null;
        return &self.submeshes[index];
    }

    /// Get a mutable submesh by index (for internal use during construction)
    pub fn getSubmeshMut(self: *MeshAsset, index: u8) ?*Submesh {
        if (index >= self.submesh_count) return null;
        return &self.submeshes[index];
    }

    /// Check if this is an indexed mesh
    pub fn isIndexed(self: *const MeshAsset) bool {
        return self.index_count > 0;
    }

    /// Get total triangle count across all submeshes
    pub fn getTotalTriangleCount(self: *const MeshAsset) u32 {
        if (!self.isIndexed()) return 0;
        return self.index_count / 3;
    }

    /// Get memory usage in bytes (vertex + index buffers)
    pub fn getGpuMemoryUsage(self: *const MeshAsset) usize {
        const vertex_bytes = @as(usize, self.vertex_count) * self.vertex_layout.getSize();
        const index_bytes = if (self.isIndexed())
            @as(usize, self.index_count) * self.index_type.getSize()
        else
            0;
        return vertex_bytes + index_bytes;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "IndexType: size calculation" {
    try testing.expectEqual(@as(usize, 2), IndexType.u16.getSize());
    try testing.expectEqual(@as(usize, 4), IndexType.u32.getSize());
}

test "VertexLayout: size calculation" {
    try testing.expectEqual(@as(usize, 64), VertexLayout.vertex3d.getSize());
}

test "Submesh: name operations" {
    var submesh: Submesh = .{};

    // Set name
    submesh.setName("test_submesh");
    try testing.expectEqualStrings("test_submesh", submesh.getName());

    // Name truncation
    const long_name = "a" ** 100;
    submesh.setName(long_name);
    try testing.expect(submesh.getName().len < 100);
    try testing.expect(submesh.getName().len == SUBMESH_NAME_MAX_LENGTH - 1);
}

test "Submesh: indexed check" {
    var submesh: Submesh = .{};
    try testing.expect(!submesh.isIndexed());

    submesh.index_count = 6;
    try testing.expect(submesh.isIndexed());
    try testing.expectEqual(@as(u32, 2), submesh.getTriangleCount());
}

test "MeshAsset: submesh access" {
    var mesh: MeshAsset = .{};
    mesh.submesh_count = 2;

    mesh.submeshes[0].setName("submesh0");
    mesh.submeshes[1].setName("submesh1");

    // Valid access
    const sub0 = mesh.getSubmesh(0);
    try testing.expect(sub0 != null);
    try testing.expectEqualStrings("submesh0", sub0.?.getName());

    // Out of bounds
    const sub_invalid = mesh.getSubmesh(5);
    try testing.expect(sub_invalid == null);
}

test "MeshAsset: memory calculation" {
    var mesh: MeshAsset = .{};
    mesh.vertex_count = 100;
    mesh.vertex_layout = .vertex3d;
    mesh.index_count = 150;
    mesh.index_type = .u32;

    const expected_bytes = (100 * 64) + (150 * 4);
    try testing.expectEqual(expected_bytes, mesh.getGpuMemoryUsage());
}
