//! MeshBuilder - CPU-side tool for constructing MeshAsset instances.
//!
//! Provides:
//! - Incremental vertex/index addition
//! - Multi-submesh construction
//! - Automatic bounds computation
//! - Normal/tangent generation
//! - Topology validation
//!
//! Usage pattern:
//! ```zig
//! var builder = MeshBuilder.init(allocator);
//! defer builder.deinit();
//!
//! // Add vertices
//! builder.addVertex(.{ .position = .{0, 0, 0}, ... });
//!
//! // Create submesh
//! builder.beginSubmesh("my_submesh");
//! builder.addIndex(0);
//! builder.addIndex(1);
//! builder.addIndex(2);
//! try builder.endSubmesh();
//!
//! // Finalize
//! try builder.computeTangents();
//! try builder.finalize();
//! ```

const std = @import("std");
const mesh_asset_types = @import("../resources/mesh_asset_types.zig");
const math_types = @import("../math/types.zig");
const math = @import("../math/math.zig");

const Submesh = mesh_asset_types.Submesh;
const IndexType = mesh_asset_types.IndexType;
const VertexLayout = mesh_asset_types.VertexLayout;
const MAX_SUBMESHES = mesh_asset_types.MAX_SUBMESHES;

// ============================================================================
// MeshBuilder
// ============================================================================

/// MeshBuilder - Mutable geometry construction tool
///
/// This structure provides a convenient API for building meshes incrementally
/// on the CPU before uploading to the GPU. It manages dynamic arrays of
/// vertices and indices, supports multiple submeshes, and provides utility
/// functions for generating normals/tangents and computing bounds.
pub const MeshBuilder = struct {
    /// Dynamic vertex array
    vertices: std.ArrayList(math_types.Vertex3D),

    /// Dynamic index array
    indices: std.ArrayList(u32),

    /// Index type (u16 or u32)
    index_type: IndexType = .u32,

    /// Fixed submesh array (max 32 submeshes)
    submeshes: [MAX_SUBMESHES]Submesh = [_]Submesh{.{}} ** MAX_SUBMESHES,

    /// Active submesh count
    submesh_count: u8 = 0,

    /// Index of the first vertex in the current submesh
    current_submesh_vertex_start: u32 = 0,

    /// Index of the first index in the current submesh
    current_submesh_index_start: u32 = 0,

    /// Whether we're currently building a submesh
    in_submesh: bool = false,

    /// Overall bounding box (updated as vertices are added)
    bounding_min: [3]f32 = .{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) },
    bounding_max: [3]f32 = .{ std.math.floatMin(f32), std.math.floatMin(f32), std.math.floatMin(f32) },

    /// Computed bounding sphere center
    bounding_center: [3]f32 = .{ 0, 0, 0 },

    /// Computed bounding sphere radius
    bounding_radius: f32 = 0,

    /// Allocator for dynamic arrays
    allocator: std.mem.Allocator,

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /// Initialize a new MeshBuilder
    pub fn init(allocator: std.mem.Allocator) MeshBuilder {
        return .{
            .vertices = .empty,
            .indices = .empty,
            .allocator = allocator,
        };
    }

    /// Deinitialize and free all resources
    pub fn deinit(self: *MeshBuilder) void {
        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
    }

    /// Reset builder to initial state (keeps allocations)
    pub fn reset(self: *MeshBuilder) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.submesh_count = 0;
        self.in_submesh = false;
        self.current_submesh_vertex_start = 0;
        self.current_submesh_index_start = 0;
        self.bounding_min = .{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
        self.bounding_max = .{ std.math.floatMin(f32), std.math.floatMin(f32), std.math.floatMin(f32) };
        self.bounding_center = .{ 0, 0, 0 };
        self.bounding_radius = 0;
    }

    // ========================================================================
    // Vertex/Index Addition
    // ========================================================================

    /// Add a vertex to the mesh
    ///
    /// The vertex position is used to update the overall bounding box.
    /// Returns the index of the added vertex.
    pub fn addVertex(self: *MeshBuilder, vertex: math_types.Vertex3D) !u32 {
        const index = @as(u32, @intCast(self.vertices.items.len));
        try self.vertices.append(self.allocator, vertex);

        // Update bounding box
        self.updateBounds(vertex.position);

        return index;
    }

    /// Add an index to the current submesh
    ///
    /// Must be called between beginSubmesh() and endSubmesh().
    /// The index must be valid (less than total vertex count).
    pub fn addIndex(self: *MeshBuilder, index: u32) !void {
        if (!self.in_submesh) {
            return error.NotInSubmesh;
        }
        try self.indices.append(self.allocator, index);
    }

    /// Add a triangle (3 indices) to the current submesh
    pub fn addTriangle(self: *MeshBuilder, idx0: u32, idx1: u32, idx2: u32) !void {
        try self.addIndex(idx0);
        try self.addIndex(idx1);
        try self.addIndex(idx2);
    }

    // ========================================================================
    // Submesh Management
    // ========================================================================

    /// Begin a new submesh
    ///
    /// All subsequent addIndex() calls will be part of this submesh
    /// until endSubmesh() is called.
    pub fn beginSubmesh(self: *MeshBuilder, name: []const u8) !void {
        if (self.in_submesh) {
            return error.AlreadyInSubmesh;
        }
        if (self.submesh_count >= MAX_SUBMESHES) {
            return error.TooManySubmeshes;
        }

        self.in_submesh = true;
        self.current_submesh_vertex_start = @intCast(self.vertices.items.len);
        self.current_submesh_index_start = @intCast(self.indices.items.len);

        // Initialize submesh
        var submesh = &self.submeshes[self.submesh_count];
        submesh.* = .{};
        submesh.setName(name);
    }

    /// End the current submesh
    ///
    /// Finalizes the submesh by computing its ranges and bounds.
    pub fn endSubmesh(self: *MeshBuilder) !void {
        if (!self.in_submesh) {
            return error.NotInSubmesh;
        }

        const submesh = &self.submeshes[self.submesh_count];

        // Compute vertex range
        const vertex_count = @as(u32, @intCast(self.vertices.items.len)) - self.current_submesh_vertex_start;
        submesh.vertex_offset = self.current_submesh_vertex_start;
        submesh.vertex_count = vertex_count;

        // Compute index range
        const index_count = @as(u32, @intCast(self.indices.items.len)) - self.current_submesh_index_start;
        submesh.index_offset = self.current_submesh_index_start;
        submesh.index_count = index_count;

        // Compute submesh bounds
        self.computeSubmeshBounds(self.submesh_count);

        self.submesh_count += 1;
        self.in_submesh = false;

        return;
    }

    // ========================================================================
    // Bounds Computation
    // ========================================================================

    /// Update overall bounding box with a new vertex position
    fn updateBounds(self: *MeshBuilder, position: [3]f32) void {
        self.bounding_min[0] = @min(self.bounding_min[0], position[0]);
        self.bounding_min[1] = @min(self.bounding_min[1], position[1]);
        self.bounding_min[2] = @min(self.bounding_min[2], position[2]);

        self.bounding_max[0] = @max(self.bounding_max[0], position[0]);
        self.bounding_max[1] = @max(self.bounding_max[1], position[1]);
        self.bounding_max[2] = @max(self.bounding_max[2], position[2]);
    }

    /// Compute bounding box and sphere for a specific submesh
    fn computeSubmeshBounds(self: *MeshBuilder, submesh_index: u8) void {
        const submesh = &self.submeshes[submesh_index];

        // If no vertices, skip
        if (submesh.vertex_count == 0) return;

        var min = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
        var max = [3]f32{ std.math.floatMin(f32), std.math.floatMin(f32), std.math.floatMin(f32) };

        // Compute AABB
        const start = submesh.vertex_offset;
        const end = start + submesh.vertex_count;
        for (self.vertices.items[start..end]) |vertex| {
            min[0] = @min(min[0], vertex.position[0]);
            min[1] = @min(min[1], vertex.position[1]);
            min[2] = @min(min[2], vertex.position[2]);

            max[0] = @max(max[0], vertex.position[0]);
            max[1] = @max(max[1], vertex.position[1]);
            max[2] = @max(max[2], vertex.position[2]);
        }

        submesh.bounding_min = min;
        submesh.bounding_max = max;

        // Compute center
        submesh.bounding_center = .{
            (min[0] + max[0]) * 0.5,
            (min[1] + max[1]) * 0.5,
            (min[2] + max[2]) * 0.5,
        };

        // Compute radius (max distance from center to any vertex)
        var max_dist_sq: f32 = 0;
        for (self.vertices.items[start..end]) |vertex| {
            const dx = vertex.position[0] - submesh.bounding_center[0];
            const dy = vertex.position[1] - submesh.bounding_center[1];
            const dz = vertex.position[2] - submesh.bounding_center[2];
            const dist_sq = dx * dx + dy * dy + dz * dz;
            max_dist_sq = @max(max_dist_sq, dist_sq);
        }
        submesh.bounding_radius = @sqrt(max_dist_sq);
    }

    /// Compute overall bounding sphere (called during finalize)
    fn computeBoundingSphere(self: *MeshBuilder) void {
        // Center is midpoint of AABB
        self.bounding_center = .{
            (self.bounding_min[0] + self.bounding_max[0]) * 0.5,
            (self.bounding_min[1] + self.bounding_max[1]) * 0.5,
            (self.bounding_min[2] + self.bounding_max[2]) * 0.5,
        };

        // Radius is max distance from center to any vertex
        var max_dist_sq: f32 = 0;
        for (self.vertices.items) |vertex| {
            const dx = vertex.position[0] - self.bounding_center[0];
            const dy = vertex.position[1] - self.bounding_center[1];
            const dz = vertex.position[2] - self.bounding_center[2];
            const dist_sq = dx * dx + dy * dy + dz * dz;
            max_dist_sq = @max(max_dist_sq, dist_sq);
        }
        self.bounding_radius = @sqrt(max_dist_sq);
    }

    // ========================================================================
    // Normal/Tangent Generation
    // ========================================================================

    /// Compute flat-shaded normals (one normal per triangle)
    ///
    /// This generates face normals by computing the cross product of triangle edges.
    /// Each vertex in a triangle gets the same normal.
    pub fn computeNormals(self: *MeshBuilder) void {
        if (self.indices.items.len < 3) return;

        var tri_idx: usize = 0;
        while (tri_idx + 2 < self.indices.items.len) : (tri_idx += 3) {
            const idx0 = self.indices.items[tri_idx];
            const idx1 = self.indices.items[tri_idx + 1];
            const idx2 = self.indices.items[tri_idx + 2];

            const v0 = &self.vertices.items[idx0];
            const v1 = &self.vertices.items[idx1];
            const v2 = &self.vertices.items[idx2];

            // Edge vectors
            const edge1 = [3]f32{
                v1.position[0] - v0.position[0],
                v1.position[1] - v0.position[1],
                v1.position[2] - v0.position[2],
            };
            const edge2 = [3]f32{
                v2.position[0] - v0.position[0],
                v2.position[1] - v0.position[1],
                v2.position[2] - v0.position[2],
            };

            // Cross product
            var normal = [3]f32{
                edge1[1] * edge2[2] - edge1[2] * edge2[1],
                edge1[2] * edge2[0] - edge1[0] * edge2[2],
                edge1[0] * edge2[1] - edge1[1] * edge2[0],
            };

            // Normalize
            const len = @sqrt(normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]);
            if (len > 0.000001) {
                normal[0] /= len;
                normal[1] /= len;
                normal[2] /= len;
            }

            // Assign to all three vertices
            self.vertices.items[idx0].normal = normal;
            self.vertices.items[idx1].normal = normal;
            self.vertices.items[idx2].normal = normal;
        }
    }

    /// Compute tangent vectors using MikkTSpace-like algorithm
    ///
    /// This generates tangent space vectors for normal mapping.
    /// Requires valid normals and texture coordinates.
    /// Adapted from OBJ loader tangent computation.
    pub fn computeTangents(self: *MeshBuilder) !void {
        if (self.indices.items.len < 3) return;

        // Initialize tangents to zero for accumulation
        for (self.vertices.items) |*v| {
            v.tangent = .{ 0, 0, 0, 0 };
        }

        // Temporary storage for bitangent accumulation
        const bitangents = try self.allocator.alloc([3]f32, self.vertices.items.len);
        defer self.allocator.free(bitangents);

        for (bitangents) |*b| {
            b.* = .{ 0, 0, 0 };
        }

        // Calculate tangent and bitangent for each triangle
        var tri_idx: usize = 0;
        while (tri_idx + 2 < self.indices.items.len) : (tri_idx += 3) {
            const idx0 = self.indices.items[tri_idx];
            const idx1 = self.indices.items[tri_idx + 1];
            const idx2 = self.indices.items[tri_idx + 2];

            const v0 = &self.vertices.items[idx0];
            const v1 = &self.vertices.items[idx1];
            const v2 = &self.vertices.items[idx2];

            // Edge vectors
            const edge1 = [3]f32{
                v1.position[0] - v0.position[0],
                v1.position[1] - v0.position[1],
                v1.position[2] - v0.position[2],
            };
            const edge2 = [3]f32{
                v2.position[0] - v0.position[0],
                v2.position[1] - v0.position[1],
                v2.position[2] - v0.position[2],
            };

            // UV edge vectors
            const duv1 = [2]f32{
                v1.texcoord[0] - v0.texcoord[0],
                v1.texcoord[1] - v0.texcoord[1],
            };
            const duv2 = [2]f32{
                v2.texcoord[0] - v0.texcoord[0],
                v2.texcoord[1] - v0.texcoord[1],
            };

            const det = duv1[0] * duv2[1] - duv1[1] * duv2[0];
            if (@abs(det) < 0.000001) continue;

            const inv_det = 1.0 / det;

            const tangent = [3]f32{
                inv_det * (duv2[1] * edge1[0] - duv1[1] * edge2[0]),
                inv_det * (duv2[1] * edge1[1] - duv1[1] * edge2[1]),
                inv_det * (duv2[1] * edge1[2] - duv1[1] * edge2[2]),
            };
            const bitangent = [3]f32{
                inv_det * (-duv2[0] * edge1[0] + duv1[0] * edge2[0]),
                inv_det * (-duv2[0] * edge1[1] + duv1[0] * edge2[1]),
                inv_det * (-duv2[0] * edge1[2] + duv1[0] * edge2[2]),
            };

            // Accumulate
            for ([_]u32{ idx0, idx1, idx2 }) |vi| {
                self.vertices.items[vi].tangent[0] += tangent[0];
                self.vertices.items[vi].tangent[1] += tangent[1];
                self.vertices.items[vi].tangent[2] += tangent[2];
                bitangents[vi][0] += bitangent[0];
                bitangents[vi][1] += bitangent[1];
                bitangents[vi][2] += bitangent[2];
            }
        }

        // Orthonormalize and compute handedness
        for (self.vertices.items, 0..) |*v, idx| {
            const n = v.normal;
            var t = [3]f32{ v.tangent[0], v.tangent[1], v.tangent[2] };

            // Gram-Schmidt orthogonalize: t = normalize(t - n * dot(n, t))
            const n_dot_t = n[0] * t[0] + n[1] * t[1] + n[2] * t[2];
            t[0] -= n[0] * n_dot_t;
            t[1] -= n[1] * n_dot_t;
            t[2] -= n[2] * n_dot_t;

            // Normalize
            const len = @sqrt(t[0] * t[0] + t[1] * t[1] + t[2] * t[2]);
            if (len > 0.000001) {
                t[0] /= len;
                t[1] /= len;
                t[2] /= len;
            } else {
                t = .{ 1, 0, 0 }; // Fallback
            }

            // Compute handedness: sign(dot(cross(n, t), bitangent))
            const cross = [3]f32{
                n[1] * t[2] - n[2] * t[1],
                n[2] * t[0] - n[0] * t[2],
                n[0] * t[1] - n[1] * t[0],
            };
            const b = bitangents[idx];
            const handedness: f32 = if (cross[0] * b[0] + cross[1] * b[1] + cross[2] * b[2] < 0) -1.0 else 1.0;

            v.tangent = .{ t[0], t[1], t[2], handedness };
        }
    }

    // ========================================================================
    // Validation & Finalization
    // ========================================================================

    /// Validate mesh topology
    ///
    /// Checks:
    /// - No out-of-bounds indices
    /// - At least one vertex
    /// - Indices are multiples of 3 (triangles)
    pub fn validate(self: *const MeshBuilder) !void {
        if (self.vertices.items.len == 0) {
            return error.NoVertices;
        }

        if (self.in_submesh) {
            return error.UnclosedSubmesh;
        }

        const vertex_count = @as(u32, @intCast(self.vertices.items.len));

        // Check indices
        if (self.indices.items.len % 3 != 0) {
            return error.InvalidTriangleCount;
        }

        for (self.indices.items) |idx| {
            if (idx >= vertex_count) {
                return error.IndexOutOfBounds;
            }
        }
    }

    /// Finalize the mesh
    ///
    /// This should be called after all vertices, indices, and submeshes have
    /// been added. It validates the mesh and computes the overall bounding sphere.
    pub fn finalize(self: *MeshBuilder) !void {
        try self.validate();
        self.computeBoundingSphere();
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "MeshBuilder: basic triangle" {
    var builder = MeshBuilder.init(testing.allocator);
    defer builder.deinit();

    // Add vertices
    _ = try builder.addVertex(.{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 0, 0 }, .tangent = .{ 1, 0, 0, 1 }, .color = .{ 1, 1, 1, 1 } });
    _ = try builder.addVertex(.{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 1, 0 }, .tangent = .{ 1, 0, 0, 1 }, .color = .{ 1, 1, 1, 1 } });
    _ = try builder.addVertex(.{ .position = .{ 0, 1, 0 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 0, 1 }, .tangent = .{ 1, 0, 0, 1 }, .color = .{ 1, 1, 1, 1 } });

    // Create submesh
    try builder.beginSubmesh("triangle");
    try builder.addTriangle(0, 1, 2);
    try builder.endSubmesh();

    // Finalize
    try builder.finalize();

    // Check results
    try testing.expectEqual(@as(usize, 3), builder.vertices.items.len);
    try testing.expectEqual(@as(usize, 3), builder.indices.items.len);
    try testing.expectEqual(@as(u8, 1), builder.submesh_count);

    const submesh = &builder.submeshes[0];
    try testing.expectEqual(@as(u32, 3), submesh.vertex_count);
    try testing.expectEqual(@as(u32, 3), submesh.index_count);
}

test "MeshBuilder: validation errors" {
    var builder = MeshBuilder.init(testing.allocator);
    defer builder.deinit();

    // No vertices
    try testing.expectError(error.NoVertices, builder.validate());

    // Add a vertex
    _ = try builder.addVertex(.{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 0, 0 }, .tangent = .{ 1, 0, 0, 1 }, .color = .{ 1, 1, 1, 1 } });

    // Unclosed submesh
    try builder.beginSubmesh("test");
    try testing.expectError(error.UnclosedSubmesh, builder.validate());
    try builder.endSubmesh();

    // Out of bounds index
    builder.indices.append(999) catch unreachable;
    try testing.expectError(error.IndexOutOfBounds, builder.validate());
}

test "MeshBuilder: bounds computation" {
    var builder = MeshBuilder.init(testing.allocator);
    defer builder.deinit();

    _ = try builder.addVertex(.{ .position = .{ -1, -1, -1 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 0, 0 }, .tangent = .{ 1, 0, 0, 1 }, .color = .{ 1, 1, 1, 1 } });
    _ = try builder.addVertex(.{ .position = .{ 1, 1, 1 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 1, 1 }, .tangent = .{ 1, 0, 0, 1 }, .color = .{ 1, 1, 1, 1 } });

    try builder.beginSubmesh("box");
    try builder.addIndex(0);
    try builder.addIndex(1);
    try builder.addIndex(0);
    try builder.endSubmesh();

    try builder.finalize();

    try testing.expectEqual([3]f32{ -1, -1, -1 }, builder.bounding_min);
    try testing.expectEqual([3]f32{ 1, 1, 1 }, builder.bounding_max);
    try testing.expectEqual([3]f32{ 0, 0, 0 }, builder.bounding_center);
}
