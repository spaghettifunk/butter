//! GeometrySystem - Manages geometry resources with ID-based registry.
//!
//! Provides:
//! - Auto-incrementing geometry IDs
//! - Name-based geometry cache/lookup
//! - Reference counting for geometries
//! - Default geometry management (quad fallback)
//! - GPU buffer management (vertex/index buffers)
//! - Procedural geometry generation (plane, cube, sphere, cylinder, cone)
//! - File loading support (OBJ, glTF)

const std = @import("std");
const builtin = @import("builtin");
const context = @import("../context.zig");
const logger = @import("../core/logging.zig");
const math_types = @import("../math/types.zig");
const math = @import("../math/math.zig");
const memory = @import("memory.zig");
const renderer = @import("../renderer/renderer.zig");
const vk_buffer = @import("../renderer/vulkan/buffer.zig");
const vk_context = @import("../renderer/vulkan/context.zig");
const vk = vk_context.vk;
const metal_buffer = @import("../renderer/metal/buffer.zig");
const metal_context = @import("../renderer/metal/context.zig");
const resource_types = @import("../resources/types.zig");
const material_system = @import("material.zig");
const obj_loader = @import("../loaders/obj_loader.zig");
const gltf_loader = @import("../loaders/gltf_loader.zig");

// ============================================================================
// Constants
// ============================================================================

/// Invalid geometry ID constant
pub const INVALID_GEOMETRY_ID: u32 = 0;

/// Maximum number of geometries that can be registered
pub const MAX_GEOMETRIES: usize = 1024;

/// Maximum length for geometry names
pub const GEOMETRY_NAME_MAX_LENGTH: u32 = 256;

/// Default geometry name
pub const DEFAULT_GEOMETRY_NAME: []const u8 = "default_quad";

// ============================================================================
// Types
// ============================================================================

/// Vertex format enum
pub const VertexFormat = enum(u8) {
    /// Simple vertex format - Vertex3D (32 bytes)
    simple,
    /// Extended vertex format - Vertex3DExtended (64 bytes)
    extended,

    pub fn getStride(self: VertexFormat) usize {
        return switch (self) {
            .simple => @sizeOf(math_types.Vertex3D),
            .extended => @sizeOf(math_types.Vertex3DExtended),
        };
    }
};

/// Index type enum
pub const IndexType = enum(u8) {
    u16,
    u32,

    pub fn getSize(self: IndexType) usize {
        return switch (self) {
            .u16 => 2,
            .u32 => 4,
        };
    }

    pub fn toVulkan(self: IndexType) vk.VkIndexType {
        return switch (self) {
            .u16 => vk.VK_INDEX_TYPE_UINT16,
            .u32 => vk.VK_INDEX_TYPE_UINT32,
        };
    }
};

/// GPU-side geometry data - supports multiple backends
pub const GeometryGpuData = union(renderer.BackendType) {
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

/// Geometry resource - represents a mesh with CPU metadata and GPU buffers
pub const Geometry = struct {
    id: u32 = 0,
    generation: u32 = 0,
    internal_id: u32 = 0,

    // Vertex data info
    vertex_count: u32 = 0,
    vertex_format: VertexFormat = .simple,

    // Index data info
    index_count: u32 = 0,
    index_type: IndexType = .u32,

    // Bounding volume (for culling)
    bounding_min: [3]f32 = .{ 0, 0, 0 },
    bounding_max: [3]f32 = .{ 0, 0, 0 },
    bounding_center: [3]f32 = .{ 0, 0, 0 },
    bounding_radius: f32 = 0,

    // Associated material (optional)
    material_id: u32 = material_system.INVALID_MATERIAL_ID,

    // GPU resources pointer
    internal_data: ?*GeometryGpuData = null,
};

/// Configuration for creating geometry from data
pub const GeometryConfig = struct {
    name: [GEOMETRY_NAME_MAX_LENGTH]u8 = [_]u8{0} ** GEOMETRY_NAME_MAX_LENGTH,

    // Vertex data
    vertex_count: u32 = 0,
    vertex_format: VertexFormat = .simple,
    vertices: ?*const anyopaque = null,

    // Index data (optional - if null, use non-indexed drawing)
    index_count: u32 = 0,
    index_type: IndexType = .u32,
    indices: ?*const anyopaque = null,

    // Optional material reference
    material_name: [resource_types.MATERIAL_NAME_MAX_LENGTH]u8 = [_]u8{0} ** resource_types.MATERIAL_NAME_MAX_LENGTH,

    // Behavior
    auto_release: bool = true,
};

/// Geometry entry in the registry
const GeometryEntry = struct {
    geometry: Geometry = .{},
    name: ?[]const u8 = null, // heap-allocated for lookup
    ref_count: u32 = 0,
    is_valid: bool = false,
    auto_release: bool = true,

    // GPU data stored inline (optional until buffers are created)
    gpu_data: ?GeometryGpuData = null,
};

// ============================================================================
// Procedural Generation Configs
// ============================================================================

/// Plane generation configuration
pub const PlaneConfig = struct {
    width: f32 = 1.0,
    height: f32 = 1.0,
    x_segments: u32 = 1,
    y_segments: u32 = 1,
    tile_x: f32 = 1.0,
    tile_y: f32 = 1.0,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    name: []const u8 = "procedural_plane",
    material_name: []const u8 = "",
    auto_release: bool = true,
};

/// Cube generation configuration
pub const CubeConfig = struct {
    width: f32 = 1.0,
    height: f32 = 1.0,
    depth: f32 = 1.0,
    tile_x: f32 = 1.0,
    tile_y: f32 = 1.0,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    name: []const u8 = "procedural_cube",
    material_name: []const u8 = "",
    auto_release: bool = true,
};

/// Sphere generation configuration
pub const SphereConfig = struct {
    radius: f32 = 0.5,
    rings: u32 = 16,
    sectors: u32 = 32,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    name: []const u8 = "procedural_sphere",
    material_name: []const u8 = "",
    auto_release: bool = true,
};

/// Cylinder generation configuration
pub const CylinderConfig = struct {
    radius_top: f32 = 0.5,
    radius_bottom: f32 = 0.5,
    height: f32 = 1.0,
    radial_segments: u32 = 32,
    height_segments: u32 = 1,
    open_ended: bool = false,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    name: []const u8 = "procedural_cylinder",
    material_name: []const u8 = "",
    auto_release: bool = true,
};

/// Cone generation configuration
pub const ConeConfig = struct {
    radius: f32 = 0.5,
    height: f32 = 1.0,
    radial_segments: u32 = 32,
    height_segments: u32 = 1,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    name: []const u8 = "procedural_cone",
    material_name: []const u8 = "",
    auto_release: bool = true,
};

// ============================================================================
// GeometrySystem
// ============================================================================

// Private instance storage
var instance: GeometrySystem = undefined;

pub const GeometrySystem = struct {
    /// Geometry registry - index is geometry ID - 1 (ID 0 is invalid)
    geometries: [MAX_GEOMETRIES]GeometryEntry,

    /// Name to geometry ID lookup (for caching)
    name_lookup: std.StringHashMap(u32),

    /// Next available geometry ID
    next_id: u32,

    /// Default geometry ID (quad for fallback)
    default_geometry_id: u32,

    /// Statistics
    total_vertex_count: u64,
    total_index_count: u64,

    /// Initialize the geometry system (called after renderer, texture, material)
    pub fn initialize() bool {
        instance = GeometrySystem{
            .geometries = [_]GeometryEntry{.{}} ** MAX_GEOMETRIES,
            .name_lookup = std.StringHashMap(u32).init(std.heap.page_allocator),
            .next_id = 1, // Start at 1, 0 is invalid
            .default_geometry_id = INVALID_GEOMETRY_ID,
            .total_vertex_count = 0,
            .total_index_count = 0,
        };

        // Create default geometry
        if (!instance.createDefaultGeometry()) {
            logger.err("Failed to create default geometry", .{});
            return false;
        }

        // Register with engine context
        context.get().geometry = &instance;
        logger.info("Geometry system initialized.", .{});
        return true;
    }

    /// Shutdown the geometry system
    pub fn shutdown() void {
        const sys = context.get().geometry orelse return;

        // Destroy all geometries
        for (&sys.geometries) |*entry| {
            if (entry.is_valid) {
                if (entry.gpu_data) |*gpu_data| {
                    sys.destroyGpuBuffers(gpu_data);
                }

                // Free the name string
                if (entry.name) |name| {
                    std.heap.page_allocator.free(name);
                }
                entry.is_valid = false;
            }
        }

        sys.name_lookup.deinit();
        context.get().geometry = null;
        logger.info("Geometry system shutdown.", .{});
    }

    // ========== Public API ==========

    /// Acquire geometry from configuration data (vertices/indices)
    /// Creates GPU buffers and stores geometry in registry
    pub fn acquireFromConfig(self: *GeometrySystem, config: GeometryConfig) ?*Geometry {
        // Convert fixed array name to slice
        const name_slice = std.mem.sliceTo(&config.name, 0);

        // Check if already exists
        if (name_slice.len > 0) {
            if (self.name_lookup.get(name_slice)) |existing_id| {
                const idx = existing_id - 1;
                self.geometries[idx].ref_count += 1;
                logger.debug("Geometry cache hit: {s} (id={}, ref_count={})", .{ name_slice, existing_id, self.geometries[idx].ref_count });
                return &self.geometries[idx].geometry;
            }
        }

        // Validate input
        if (config.vertex_count == 0 or config.vertices == null) {
            logger.err("Cannot create geometry with no vertices", .{});
            return null;
        }

        // Allocate new geometry ID
        const geometry_id = self.allocateId() orelse {
            logger.err("No free geometry slots available", .{});
            return null;
        };

        const idx = geometry_id - 1;
        var entry = &self.geometries[idx];

        // Create GPU buffers
        const vertex_size = config.vertex_count * config.vertex_format.getStride();
        const vertices_bytes: [*]const u8 = @ptrCast(config.vertices.?);

        var indices_bytes: ?[*]const u8 = null;
        var index_size: usize = 0;
        if (config.indices != null and config.index_count > 0) {
            index_size = config.index_count * config.index_type.getSize();
            indices_bytes = @ptrCast(config.indices.?);
        }

        // Initialize gpu_data with a dummy value that will be overwritten
        entry.gpu_data = .{ .vulkan = .{} }; // Will be overwritten by createGpuBuffers

        if (!self.createGpuBuffers(
            &entry.gpu_data.?,
            vertices_bytes[0..vertex_size],
            if (indices_bytes) |ib| ib[0..index_size] else null,
        )) {
            logger.err("Failed to create GPU buffers for geometry '{s}'", .{name_slice});
            entry.gpu_data = null;
            return null;
        }

        // Populate the geometry
        entry.geometry.id = geometry_id;
        entry.geometry.generation = 0;
        entry.geometry.internal_id = 0;
        entry.geometry.vertex_count = config.vertex_count;
        entry.geometry.vertex_format = config.vertex_format;
        entry.geometry.index_count = config.index_count;
        entry.geometry.index_type = config.index_type;
        entry.geometry.internal_data = &entry.gpu_data.?;

        // Compute bounding box
        self.computeBoundingBox(entry, config);

        // Try to acquire material if specified
        const material_name_slice = std.mem.sliceTo(&config.material_name, 0);
        if (material_name_slice.len > 0) {
            if (material_system.acquire(material_name_slice)) |mat| {
                entry.geometry.material_id = mat.id;
            }
        }

        entry.ref_count = 1;
        entry.is_valid = true;
        entry.auto_release = config.auto_release;

        // Store name for cache lookup
        if (name_slice.len > 0) {
            const name_copy = std.heap.page_allocator.dupe(u8, name_slice) catch {
                logger.err("Failed to allocate name for geometry cache", .{});
                return &entry.geometry; // Still return valid geometry
            };

            entry.name = name_copy;
            self.name_lookup.put(name_copy, geometry_id) catch {
                logger.warn("Failed to add geometry to cache: {s}", .{name_slice});
                std.heap.page_allocator.free(name_copy);
                entry.name = null;
            };
        }

        // Update statistics
        self.total_vertex_count += config.vertex_count;
        self.total_index_count += config.index_count;

        logger.info("Geometry created: {s} (id={}, vertices={}, indices={})", .{
            if (name_slice.len > 0) name_slice else "<unnamed>",
            geometry_id,
            config.vertex_count,
            config.index_count,
        });

        return &entry.geometry;
    }

    /// Acquire geometry by name. Loads from file if not cached.
    pub fn acquire(self: *GeometrySystem, name: []const u8) ?*Geometry {
        // Check cache first
        if (self.name_lookup.get(name)) |existing_id| {
            const idx = existing_id - 1;
            self.geometries[idx].ref_count += 1;
            logger.debug("Geometry cache hit: {s} (id={}, ref_count={})", .{ name, existing_id, self.geometries[idx].ref_count });
            return &self.geometries[idx].geometry;
        }

        // Not in cache, try to load from file
        return self.loadFromFile(name);
    }

    /// Load geometry from a file (OBJ, glTF, GLB)
    pub fn loadFromFile(self: *GeometrySystem, path: []const u8) ?*Geometry {
        const allocator = std.heap.page_allocator;

        // Detect format from extension
        const ext = getFileExtension(path);

        if (std.mem.eql(u8, ext, "obj")) {
            return self.loadFromObj(allocator, path);
        } else if (std.mem.eql(u8, ext, "gltf") or std.mem.eql(u8, ext, "glb")) {
            return self.loadFromGltf(allocator, path);
        }

        logger.warn("Unsupported geometry format: {s}", .{ext});
        return self.getDefault();
    }

    fn loadFromObj(self: *GeometrySystem, allocator: std.mem.Allocator, path: []const u8) ?*Geometry {
        var result = obj_loader.loadObj(allocator, path) orelse {
            logger.warn("Failed to load OBJ file: {s}, using default", .{path});
            return self.getDefault();
        };
        defer result.deinit();

        if (result.vertices.len == 0) {
            return self.getDefault();
        }

        // Extract filename for geometry name
        const name = getFileName(path);

        // Create geometry config
        var config: GeometryConfig = .{
            .vertex_count = @intCast(result.vertices.len),
            .vertex_format = .extended,
            .vertices = result.vertices.ptr,
            .index_count = @intCast(result.indices.len),
            .index_type = .u32,
            .indices = result.indices.ptr,
            .auto_release = true,
        };

        // Copy name
        const name_len = @min(name.len, GEOMETRY_NAME_MAX_LENGTH - 1);
        @memcpy(config.name[0..name_len], name[0..name_len]);

        // Try to get material from first sub-mesh
        if (result.sub_meshes.len > 0 and result.sub_meshes[0].material_name.len > 0) {
            const mat_len = @min(result.sub_meshes[0].material_name.len, resource_types.MATERIAL_NAME_MAX_LENGTH - 1);
            @memcpy(config.material_name[0..mat_len], result.sub_meshes[0].material_name[0..mat_len]);
        }

        return self.acquireFromConfig(config);
    }

    fn loadFromGltf(self: *GeometrySystem, allocator: std.mem.Allocator, path: []const u8) ?*Geometry {
        var result = gltf_loader.loadGltf(allocator, path) orelse {
            logger.warn("Failed to load glTF file: {s}, using default", .{path});
            return self.getDefault();
        };
        defer result.deinit();

        if (result.meshes.len == 0) {
            return self.getDefault();
        }

        // Use first mesh, first primitive for now
        const mesh = result.meshes[0];
        if (mesh.primitives.len == 0) {
            return self.getDefault();
        }

        const prim = mesh.primitives[0];

        // Use mesh name or filename
        const name = if (mesh.name.len > 0) mesh.name else getFileName(path);

        // Create geometry config
        var config: GeometryConfig = .{
            .vertex_count = @intCast(prim.vertices.len),
            .vertex_format = .extended,
            .vertices = prim.vertices.ptr,
            .index_count = @intCast(prim.indices.len),
            .index_type = .u32,
            .indices = prim.indices.ptr,
            .auto_release = true,
        };

        // Copy name
        const name_len = @min(name.len, GEOMETRY_NAME_MAX_LENGTH - 1);
        @memcpy(config.name[0..name_len], name[0..name_len]);

        return self.acquireFromConfig(config);
    }

    /// Acquire geometry by ID (increments ref count)
    pub fn acquireById(self: *GeometrySystem, id: u32) ?*Geometry {
        if (id == INVALID_GEOMETRY_ID) return null;

        const idx = id - 1;
        if (idx >= MAX_GEOMETRIES or !self.geometries[idx].is_valid) return null;

        self.geometries[idx].ref_count += 1;
        return &self.geometries[idx].geometry;
    }

    /// Get geometry without incrementing ref count
    pub fn getGeometry(self: *GeometrySystem, id: u32) ?*Geometry {
        if (id == INVALID_GEOMETRY_ID) return null;

        const idx = id - 1;
        if (idx >= MAX_GEOMETRIES) return null;
        if (!self.geometries[idx].is_valid) return null;

        return &self.geometries[idx].geometry;
    }

    /// Release a geometry by ID.
    /// Destroys if ref_count reaches 0 and auto_release is true.
    pub fn release(self: *GeometrySystem, id: u32) void {
        if (id == INVALID_GEOMETRY_ID) return;
        if (id == self.default_geometry_id) return; // Never release default

        const idx = id - 1;
        if (idx >= MAX_GEOMETRIES or !self.geometries[idx].is_valid) return;

        if (self.geometries[idx].ref_count > 0) {
            self.geometries[idx].ref_count -= 1;
        }

        if (self.geometries[idx].ref_count == 0 and self.geometries[idx].auto_release) {
            const entry = &self.geometries[idx];

            // Update statistics
            if (self.total_vertex_count >= entry.geometry.vertex_count) {
                self.total_vertex_count -= entry.geometry.vertex_count;
            }
            if (self.total_index_count >= entry.geometry.index_count) {
                self.total_index_count -= entry.geometry.index_count;
            }

            // Destroy GPU buffers
            if (entry.gpu_data) |*gpu_data| {
                self.destroyGpuBuffers(gpu_data);
                entry.gpu_data = null;
            }

            // Release material if any
            if (entry.geometry.material_id != material_system.INVALID_MATERIAL_ID) {
                // Note: Material release uses name, not ID. We'd need to track the name.
                // For now, materials will be released when material system shuts down.
            }

            // Remove from name cache
            if (entry.name) |geo_name| {
                _ = self.name_lookup.remove(geo_name);
                std.heap.page_allocator.free(geo_name);
            }

            entry.is_valid = false;
            entry.name = null;
            logger.debug("Geometry released and destroyed (id={})", .{id});
        }
    }

    /// Get the default geometry (quad fallback)
    pub fn getDefault(self: *GeometrySystem) ?*Geometry {
        return self.getGeometry(self.default_geometry_id);
    }

    /// Get the default geometry ID
    pub fn getDefaultId(self: *GeometrySystem) u32 {
        return self.default_geometry_id;
    }

    // ========== Procedural Generators ==========

    /// Generate a plane geometry
    pub fn generatePlane(self: *GeometrySystem, config: PlaneConfig) ?*Geometry {
        const x_segs = if (config.x_segments < 1) 1 else config.x_segments;
        const y_segs = if (config.y_segments < 1) 1 else config.y_segments;

        const vertex_count = (x_segs + 1) * (y_segs + 1);
        // Double the index count for double-sided plane (visible from both above and below)
        const index_count = x_segs * y_segs * 6 * 2;

        const allocator = std.heap.page_allocator;

        // Allocate temporary arrays - use simple Vertex3D format
        const vertices = allocator.alloc(math_types.Vertex3D, vertex_count) catch {
            logger.err("Failed to allocate vertices for plane generation", .{});
            return null;
        };
        defer allocator.free(vertices);

        const indices = allocator.alloc(u32, index_count) catch {
            logger.err("Failed to allocate indices for plane generation", .{});
            return null;
        };
        defer allocator.free(indices);

        // Generate vertices
        const half_width = config.width / 2.0;
        const half_height = config.height / 2.0;

        var v_idx: usize = 0;
        for (0..y_segs + 1) |y| {
            const v: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(y_segs));
            for (0..x_segs + 1) |x| {
                const u: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(x_segs));

                vertices[v_idx] = .{
                    .position = .{
                        u * config.width - half_width,
                        0.0,
                        v * config.height - half_height,
                    },
                    .color = config.color,
                    .texcoord = .{ u * config.tile_x, v * config.tile_y },
                };
                v_idx += 1;
            }
        }

        // Generate indices for plane visible from ABOVE (+Y direction)
        // Vulkan uses Y-down in NDC, so we need CLOCKWISE winding in world space
        // to get CCW in screen space (which is the front face).
        //
        // Vertex layout in XZ plane when looking down from +Y:
        //   +Z (forward/up in view)
        //    ^
        //    |
        //   bl (low x, high z) ----- br (high x, high z)
        //    |                         |
        //    |                         |
        //   tl (low x, low z)  ----- tr (high x, low z)
        //    |
        //    +-----> +X (right)
        //
        // CW from +Y (for Vulkan): tl -> bl -> br, tl -> br -> tr
        var i_idx: usize = 0;
        for (0..y_segs) |y| {
            for (0..x_segs) |x| {
                const row_start = y * (x_segs + 1);
                const next_row_start = (y + 1) * (x_segs + 1);

                const tl: u32 = @intCast(row_start + x);
                const tr: u32 = @intCast(row_start + x + 1);
                const bl: u32 = @intCast(next_row_start + x);
                const br: u32 = @intCast(next_row_start + x + 1);

                // CW winding in world space (becomes CCW in Vulkan screen space)
                // Visible from above (+Y)
                indices[i_idx] = tl;
                indices[i_idx + 1] = bl;
                indices[i_idx + 2] = br;
                indices[i_idx + 3] = tl;
                indices[i_idx + 4] = br;
                indices[i_idx + 5] = tr;
                i_idx += 6;
            }
        }

        // Add back-face indices (reversed winding for visibility from below -Y)
        // CCW from +Y = CW from -Y (visible from below)
        for (0..y_segs) |y| {
            for (0..x_segs) |x| {
                const row_start = y * (x_segs + 1);
                const next_row_start = (y + 1) * (x_segs + 1);

                const tl: u32 = @intCast(row_start + x);
                const tr: u32 = @intCast(row_start + x + 1);
                const bl: u32 = @intCast(next_row_start + x);
                const br: u32 = @intCast(next_row_start + x + 1);

                // CCW winding in world space (reversed from front face)
                // Visible from below (-Y)
                indices[i_idx] = tl;
                indices[i_idx + 1] = br;
                indices[i_idx + 2] = bl;
                indices[i_idx + 3] = tl;
                indices[i_idx + 4] = tr;
                indices[i_idx + 5] = br;
                i_idx += 6;
            }
        }

        // Create geometry config
        var geo_config: GeometryConfig = .{
            .vertex_count = @intCast(vertex_count),
            .vertex_format = .simple,
            .vertices = vertices.ptr,
            .index_count = @intCast(index_count),
            .index_type = .u32,
            .indices = indices.ptr,
            .auto_release = config.auto_release,
        };

        // Copy name
        const name_len = @min(config.name.len, GEOMETRY_NAME_MAX_LENGTH - 1);
        @memcpy(geo_config.name[0..name_len], config.name[0..name_len]);

        // Copy material name
        const mat_len = @min(config.material_name.len, resource_types.MATERIAL_NAME_MAX_LENGTH - 1);
        @memcpy(geo_config.material_name[0..mat_len], config.material_name[0..mat_len]);

        return self.acquireFromConfig(geo_config);
    }

    /// Generate a cube geometry
    pub fn generateCube(self: *GeometrySystem, config: CubeConfig) ?*Geometry {
        const allocator = std.heap.page_allocator;

        // 24 vertices (4 per face for correct normals)
        const vertex_count: usize = 24;
        const index_count: usize = 36;

        const vertices = allocator.alloc(math_types.Vertex3D, vertex_count) catch {
            logger.err("Failed to allocate vertices for cube generation", .{});
            return null;
        };
        defer allocator.free(vertices);

        const indices = allocator.alloc(u32, index_count) catch {
            logger.err("Failed to allocate indices for cube generation", .{});
            return null;
        };
        defer allocator.free(indices);

        const hw = config.width / 2.0;
        const hh = config.height / 2.0;
        const hd = config.depth / 2.0;

        // Define faces: vertices per face
        const face_verts = [_][4][3]f32{
            // Front (+Z)
            .{ .{ -hw, -hh, hd }, .{ hw, -hh, hd }, .{ hw, hh, hd }, .{ -hw, hh, hd } },
            // Back (-Z)
            .{ .{ hw, -hh, -hd }, .{ -hw, -hh, -hd }, .{ -hw, hh, -hd }, .{ hw, hh, -hd } },
            // Left (-X)
            .{ .{ -hw, -hh, -hd }, .{ -hw, -hh, hd }, .{ -hw, hh, hd }, .{ -hw, hh, -hd } },
            // Right (+X)
            .{ .{ hw, -hh, hd }, .{ hw, -hh, -hd }, .{ hw, hh, -hd }, .{ hw, hh, hd } },
            // Top (+Y)
            .{ .{ -hw, hh, hd }, .{ hw, hh, hd }, .{ hw, hh, -hd }, .{ -hw, hh, -hd } },
            // Bottom (-Y)
            .{ .{ -hw, -hh, -hd }, .{ hw, -hh, -hd }, .{ hw, -hh, hd }, .{ -hw, -hh, hd } },
        };

        const uvs = [4][2]f32{
            .{ 0.0, config.tile_y },
            .{ config.tile_x, config.tile_y },
            .{ config.tile_x, 0.0 },
            .{ 0.0, 0.0 },
        };

        for (face_verts, 0..) |face, face_idx| {
            const base_vertex: u32 = @intCast(face_idx * 4);
            for (face, 0..) |pos, vert_idx| {
                vertices[face_idx * 4 + vert_idx] = .{
                    .position = pos,
                    .color = config.color,
                    .texcoord = uvs[vert_idx],
                };
            }

            // Indices for this face (CW winding in world space for Vulkan)
            // Face vertices are defined CW: 0(bl) -> 1(br) -> 2(tr) -> 3(tl)
            // CW in world space: 0 -> 1 -> 2 and 0 -> 2 -> 3
            const i_base = face_idx * 6;
            indices[i_base + 0] = base_vertex + 0;
            indices[i_base + 1] = base_vertex + 1;
            indices[i_base + 2] = base_vertex + 2;
            indices[i_base + 3] = base_vertex + 0;
            indices[i_base + 4] = base_vertex + 2;
            indices[i_base + 5] = base_vertex + 3;
        }

        // Create geometry config
        var geo_config: GeometryConfig = .{
            .vertex_count = @intCast(vertex_count),
            .vertex_format = .simple,
            .vertices = vertices.ptr,
            .index_count = @intCast(index_count),
            .index_type = .u32,
            .indices = indices.ptr,
            .auto_release = config.auto_release,
        };

        // Copy names
        const name_len = @min(config.name.len, GEOMETRY_NAME_MAX_LENGTH - 1);
        @memcpy(geo_config.name[0..name_len], config.name[0..name_len]);

        const mat_len = @min(config.material_name.len, resource_types.MATERIAL_NAME_MAX_LENGTH - 1);
        @memcpy(geo_config.material_name[0..mat_len], config.material_name[0..mat_len]);

        return self.acquireFromConfig(geo_config);
    }

    /// Generate a UV sphere geometry
    pub fn generateSphere(self: *GeometrySystem, config: SphereConfig) ?*Geometry {
        const rings = if (config.rings < 3) 3 else config.rings;
        const sectors = if (config.sectors < 3) 3 else config.sectors;

        const vertex_count = (rings + 1) * (sectors + 1);
        const index_count = rings * sectors * 6;

        const allocator = std.heap.page_allocator;

        const vertices = allocator.alloc(math_types.Vertex3D, vertex_count) catch {
            logger.err("Failed to allocate vertices for sphere generation", .{});
            return null;
        };
        defer allocator.free(vertices);

        const indices = allocator.alloc(u32, index_count) catch {
            logger.err("Failed to allocate indices for sphere generation", .{});
            return null;
        };
        defer allocator.free(indices);

        // Generate vertices
        var v_idx: usize = 0;
        for (0..rings + 1) |ring| {
            const phi: f32 = math.K_PI * @as(f32, @floatFromInt(ring)) / @as(f32, @floatFromInt(rings));
            const sin_phi = @sin(phi);
            const cos_phi = @cos(phi);

            for (0..sectors + 1) |sector| {
                const theta: f32 = 2.0 * math.K_PI * @as(f32, @floatFromInt(sector)) / @as(f32, @floatFromInt(sectors));
                const sin_theta = @sin(theta);
                const cos_theta = @cos(theta);

                const x = sin_phi * cos_theta;
                const y = cos_phi;
                const z = sin_phi * sin_theta;

                const u = @as(f32, @floatFromInt(sector)) / @as(f32, @floatFromInt(sectors));
                const v = @as(f32, @floatFromInt(ring)) / @as(f32, @floatFromInt(rings));

                vertices[v_idx] = .{
                    .position = .{ x * config.radius, y * config.radius, z * config.radius },
                    .color = config.color,
                    .texcoord = .{ u, v },
                };
                v_idx += 1;
            }
        }

        // Generate indices (CW winding in world space for Vulkan)
        // For sphere: ring 0 is top (y=1), ring N is bottom (y=-1)
        // tl/tr are higher (smaller ring), bl/br are lower (larger ring)
        // Sectors increase going around Y axis (e.g., +X to +Z to -X...)
        // CW from outside in world space -> CCW in Vulkan screen space
        var i_idx: usize = 0;
        for (0..rings) |ring| {
            for (0..sectors) |sector| {
                const row_start = ring * (sectors + 1);
                const next_row_start = (ring + 1) * (sectors + 1);

                const tl: u32 = @intCast(row_start + sector);
                const tr: u32 = @intCast(row_start + sector + 1);
                const bl: u32 = @intCast(next_row_start + sector);
                const br: u32 = @intCast(next_row_start + sector + 1);

                // CW winding from outside: tl -> bl -> tr, tr -> bl -> br
                indices[i_idx] = tl;
                indices[i_idx + 1] = bl;
                indices[i_idx + 2] = tr;
                indices[i_idx + 3] = tr;
                indices[i_idx + 4] = bl;
                indices[i_idx + 5] = br;
                i_idx += 6;
            }
        }

        // Create geometry config
        var geo_config: GeometryConfig = .{
            .vertex_count = @intCast(vertex_count),
            .vertex_format = .simple,
            .vertices = vertices.ptr,
            .index_count = @intCast(index_count),
            .index_type = .u32,
            .indices = indices.ptr,
            .auto_release = config.auto_release,
        };

        const name_len = @min(config.name.len, GEOMETRY_NAME_MAX_LENGTH - 1);
        @memcpy(geo_config.name[0..name_len], config.name[0..name_len]);

        const mat_len = @min(config.material_name.len, resource_types.MATERIAL_NAME_MAX_LENGTH - 1);
        @memcpy(geo_config.material_name[0..mat_len], config.material_name[0..mat_len]);

        return self.acquireFromConfig(geo_config);
    }

    /// Generate a cylinder geometry
    pub fn generateCylinder(self: *GeometrySystem, config: CylinderConfig) ?*Geometry {
        const radial_segs = if (config.radial_segments < 3) 3 else config.radial_segments;
        const height_segs = if (config.height_segments < 1) 1 else config.height_segments;

        // Calculate vertex and index counts
        var vertex_count: usize = (height_segs + 1) * (radial_segs + 1);
        var index_count: usize = height_segs * radial_segs * 6;

        if (!config.open_ended) {
            vertex_count += (radial_segs + 1) * 2 + 2;
            index_count += radial_segs * 3 * 2;
        }

        const allocator = std.heap.page_allocator;

        const vertices = allocator.alloc(math_types.Vertex3D, vertex_count) catch {
            logger.err("Failed to allocate vertices for cylinder generation", .{});
            return null;
        };
        defer allocator.free(vertices);

        const indices = allocator.alloc(u32, index_count) catch {
            logger.err("Failed to allocate indices for cylinder generation", .{});
            return null;
        };
        defer allocator.free(indices);

        const half_height = config.height / 2.0;

        // Generate side vertices
        var v_idx: usize = 0;
        for (0..height_segs + 1) |h| {
            const v: f32 = @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(height_segs));
            const y = v * config.height - half_height;
            const radius = config.radius_bottom + (config.radius_top - config.radius_bottom) * v;

            for (0..radial_segs + 1) |r| {
                const u: f32 = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(radial_segs));
                const theta = u * 2.0 * math.K_PI;
                const cos_theta = @cos(theta);
                const sin_theta = @sin(theta);

                vertices[v_idx] = .{
                    .position = .{ radius * cos_theta, y, radius * sin_theta },
                    .color = config.color,
                    .texcoord = .{ u, v },
                };
                v_idx += 1;
            }
        }

        // Generate side indices (CW winding in world space for Vulkan)
        // For cylinder: h=0 is top, h=N is bottom
        // Radial segments go around Y axis
        // CW from outside in world space -> CCW in Vulkan screen space
        var i_idx: usize = 0;
        for (0..height_segs) |h| {
            for (0..radial_segs) |r| {
                const row_start = h * (radial_segs + 1);
                const next_row_start = (h + 1) * (radial_segs + 1);

                const tl: u32 = @intCast(row_start + r);
                const tr: u32 = @intCast(row_start + r + 1);
                const bl: u32 = @intCast(next_row_start + r);
                const br: u32 = @intCast(next_row_start + r + 1);

                // CW winding from outside: tl -> bl -> tr, tr -> bl -> br
                indices[i_idx] = tl;
                indices[i_idx + 1] = bl;
                indices[i_idx + 2] = tr;
                indices[i_idx + 3] = tr;
                indices[i_idx + 4] = bl;
                indices[i_idx + 5] = br;
                i_idx += 6;
            }
        }

        // Generate caps if not open ended
        if (!config.open_ended) {
            // Top cap center
            const top_center_idx: u32 = @intCast(v_idx);
            vertices[v_idx] = .{ .position = .{ 0.0, half_height, 0.0 }, .color = config.color, .texcoord = .{ 0.5, 0.5 } };
            v_idx += 1;

            for (0..radial_segs + 1) |r| {
                const u: f32 = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(radial_segs));
                const theta = u * 2.0 * math.K_PI;
                vertices[v_idx] = .{
                    .position = .{ config.radius_top * @cos(theta), half_height, config.radius_top * @sin(theta) },
                    .color = config.color,
                    .texcoord = .{ @cos(theta) * 0.5 + 0.5, @sin(theta) * 0.5 + 0.5 },
                };
                v_idx += 1;
            }

            // Top cap triangles (CCW when viewed from above)
            for (0..radial_segs) |r| {
                indices[i_idx] = top_center_idx;
                indices[i_idx + 1] = @intCast(top_center_idx + 2 + r);
                indices[i_idx + 2] = @intCast(top_center_idx + 1 + r);
                i_idx += 3;
            }

            // Bottom cap center
            const bottom_center_idx: u32 = @intCast(v_idx);
            vertices[v_idx] = .{ .position = .{ 0.0, -half_height, 0.0 }, .color = config.color, .texcoord = .{ 0.5, 0.5 } };
            v_idx += 1;

            for (0..radial_segs + 1) |r| {
                const u: f32 = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(radial_segs));
                const theta = u * 2.0 * math.K_PI;
                vertices[v_idx] = .{
                    .position = .{ config.radius_bottom * @cos(theta), -half_height, config.radius_bottom * @sin(theta) },
                    .color = config.color,
                    .texcoord = .{ @cos(theta) * 0.5 + 0.5, @sin(theta) * 0.5 + 0.5 },
                };
                v_idx += 1;
            }

            // Bottom cap triangles (CCW when viewed from below)
            for (0..radial_segs) |r| {
                indices[i_idx] = bottom_center_idx;
                indices[i_idx + 1] = @intCast(bottom_center_idx + 1 + r);
                indices[i_idx + 2] = @intCast(bottom_center_idx + 2 + r);
                i_idx += 3;
            }
        }

        // Create geometry config
        var geo_config: GeometryConfig = .{
            .vertex_count = @intCast(v_idx),
            .vertex_format = .simple,
            .vertices = vertices.ptr,
            .index_count = @intCast(i_idx),
            .index_type = .u32,
            .indices = indices.ptr,
            .auto_release = config.auto_release,
        };

        const name_len = @min(config.name.len, GEOMETRY_NAME_MAX_LENGTH - 1);
        @memcpy(geo_config.name[0..name_len], config.name[0..name_len]);

        const mat_len = @min(config.material_name.len, resource_types.MATERIAL_NAME_MAX_LENGTH - 1);
        @memcpy(geo_config.material_name[0..mat_len], config.material_name[0..mat_len]);

        return self.acquireFromConfig(geo_config);
    }

    /// Generate a cone geometry (cylinder with top radius = 0)
    pub fn generateCone(self: *GeometrySystem, config: ConeConfig) ?*Geometry {
        return self.generateCylinder(.{
            .radius_top = 0.0,
            .radius_bottom = config.radius,
            .height = config.height,
            .radial_segments = config.radial_segments,
            .height_segments = config.height_segments,
            .open_ended = false,
            .color = config.color,
            .name = config.name,
            .material_name = config.material_name,
            .auto_release = config.auto_release,
        });
    }

    // ========== Private helpers ==========

    fn createDefaultGeometry(self: *GeometrySystem) bool {
        // Create a simple quad (4 vertices, 6 indices) using extended vertex format
        const vertices = [_]math_types.Vertex3DExtended{
            // Bottom-left
            .{
                .position = .{ -0.5, 0.0, -0.5 },
                .normal = .{ 0.0, 1.0, 0.0 },
                .texcoord = .{ 0.0, 1.0 },
                .tangent = .{ 1.0, 0.0, 0.0, 1.0 },
                .color = .{ 1.0, 1.0, 1.0, 1.0 },
            },
            // Bottom-right
            .{
                .position = .{ 0.5, 0.0, -0.5 },
                .normal = .{ 0.0, 1.0, 0.0 },
                .texcoord = .{ 1.0, 1.0 },
                .tangent = .{ 1.0, 0.0, 0.0, 1.0 },
                .color = .{ 1.0, 1.0, 1.0, 1.0 },
            },
            // Top-right
            .{
                .position = .{ 0.5, 0.0, 0.5 },
                .normal = .{ 0.0, 1.0, 0.0 },
                .texcoord = .{ 1.0, 0.0 },
                .tangent = .{ 1.0, 0.0, 0.0, 1.0 },
                .color = .{ 1.0, 1.0, 1.0, 1.0 },
            },
            // Top-left
            .{
                .position = .{ -0.5, 0.0, 0.5 },
                .normal = .{ 0.0, 1.0, 0.0 },
                .texcoord = .{ 0.0, 0.0 },
                .tangent = .{ 1.0, 0.0, 0.0, 1.0 },
                .color = .{ 1.0, 1.0, 1.0, 1.0 },
            },
        };

        const indices = [_]u32{ 0, 1, 2, 2, 3, 0 };

        var config: GeometryConfig = .{
            .vertex_count = 4,
            .vertex_format = .extended,
            .vertices = &vertices,
            .index_count = 6,
            .index_type = .u32,
            .indices = &indices,
            .auto_release = false,
        };

        // Set name
        @memcpy(config.name[0..DEFAULT_GEOMETRY_NAME.len], DEFAULT_GEOMETRY_NAME);

        const geo = self.acquireFromConfig(config);
        if (geo == null) return false;

        self.default_geometry_id = geo.?.id;
        logger.info("Default geometry created (id={})", .{self.default_geometry_id});
        return true;
    }

    fn createGpuBuffers(
        self: *GeometrySystem,
        gpu_data: *GeometryGpuData,
        vertices: []const u8,
        indices: ?[]const u8,
    ) bool {
        _ = self;

        const render_sys = renderer.getSystem() orelse {
            logger.err("Renderer system not available for geometry creation", .{});
            return false;
        };

        switch (render_sys.backend) {
            .vulkan => |*v| {
                return createVulkanBuffers(&v.context, gpu_data, vertices, indices);
            },
            .metal => |*m| {
                return createMetalBuffers(&m.context, gpu_data, vertices, indices);
            },
            else => {
                logger.err("Geometry system does not support this backend", .{});
                return false;
            },
        }
    }

    fn createVulkanBuffers(
        vk_ctx: *vk_context.VulkanContext,
        gpu_data: *GeometryGpuData,
        vertices: []const u8,
        indices: ?[]const u8,
    ) bool {
        // Initialize as vulkan variant
        gpu_data.* = .{ .vulkan = .{} };

        // Create vertex buffer (staging -> device local)
        const vertex_size: vk.VkDeviceSize = vertices.len;

        // Create staging buffer
        var vertex_staging: vk_buffer.VulkanBuffer = .{};
        if (!vk_buffer.create(vk_ctx, &vertex_staging, vertex_size, vk_buffer.BufferUsage.staging, vk_buffer.MemoryFlags.host_visible)) {
            logger.err("Failed to create vertex staging buffer", .{});
            return false;
        }

        // Load data to staging
        if (!vk_buffer.loadData(vk_ctx, &vertex_staging, 0, vertex_size, vertices.ptr)) {
            logger.err("Failed to load vertex data to staging buffer", .{});
            vk_buffer.destroy(vk_ctx, &vertex_staging);
            return false;
        }

        // Create device-local vertex buffer
        if (!vk_buffer.create(vk_ctx, &gpu_data.vulkan.vertex_buffer, vertex_size, vk_buffer.BufferUsage.vertex, vk_buffer.MemoryFlags.device_local)) {
            logger.err("Failed to create device-local vertex buffer", .{});
            vk_buffer.destroy(vk_ctx, &vertex_staging);
            return false;
        }

        // Copy staging to device
        if (!vk_buffer.copyTo(vk_ctx, vk_ctx.graphics_command_pool, &vertex_staging, &gpu_data.vulkan.vertex_buffer, vertex_size)) {
            logger.err("Failed to copy vertex data to device buffer", .{});
            vk_buffer.destroy(vk_ctx, &vertex_staging);
            vk_buffer.destroy(vk_ctx, &gpu_data.vulkan.vertex_buffer);
            return false;
        }

        // Clean up staging
        vk_buffer.destroy(vk_ctx, &vertex_staging);

        // Create index buffer if indices provided
        if (indices) |idx_data| {
            const index_size: vk.VkDeviceSize = idx_data.len;

            var index_staging: vk_buffer.VulkanBuffer = .{};
            if (!vk_buffer.create(vk_ctx, &index_staging, index_size, vk_buffer.BufferUsage.staging, vk_buffer.MemoryFlags.host_visible)) {
                logger.err("Failed to create index staging buffer", .{});
                vk_buffer.destroy(vk_ctx, &gpu_data.vulkan.vertex_buffer);
                return false;
            }

            if (!vk_buffer.loadData(vk_ctx, &index_staging, 0, index_size, idx_data.ptr)) {
                logger.err("Failed to load index data to staging buffer", .{});
                vk_buffer.destroy(vk_ctx, &index_staging);
                vk_buffer.destroy(vk_ctx, &gpu_data.vulkan.vertex_buffer);
                return false;
            }

            if (!vk_buffer.create(vk_ctx, &gpu_data.vulkan.index_buffer, index_size, vk_buffer.BufferUsage.index, vk_buffer.MemoryFlags.device_local)) {
                logger.err("Failed to create device-local index buffer", .{});
                vk_buffer.destroy(vk_ctx, &index_staging);
                vk_buffer.destroy(vk_ctx, &gpu_data.vulkan.vertex_buffer);
                return false;
            }

            if (!vk_buffer.copyTo(vk_ctx, vk_ctx.graphics_command_pool, &index_staging, &gpu_data.vulkan.index_buffer, index_size)) {
                logger.err("Failed to copy index data to device buffer", .{});
                vk_buffer.destroy(vk_ctx, &index_staging);
                vk_buffer.destroy(vk_ctx, &gpu_data.vulkan.vertex_buffer);
                vk_buffer.destroy(vk_ctx, &gpu_data.vulkan.index_buffer);
                return false;
            }

            vk_buffer.destroy(vk_ctx, &index_staging);
        }

        return true;
    }

    fn createMetalBuffers(
        mtl_ctx: *metal_context.MetalContext,
        gpu_data: *GeometryGpuData,
        vertices: []const u8,
        indices: ?[]const u8,
    ) bool {
        // Initialize as metal variant
        gpu_data.* = .{ .metal = .{} };

        // Metal uses shared storage on Apple Silicon, so we can create buffers directly with data
        const vertex_buf = metal_buffer.create(mtl_ctx, vertices.len, vertices.ptr);
        if (!metal_buffer.isValid(&vertex_buf)) {
            logger.err("Failed to create Metal vertex buffer", .{});
            return false;
        }
        gpu_data.metal.vertex_buffer = vertex_buf;

        // Create index buffer if indices provided
        if (indices) |idx_data| {
            const index_buf = metal_buffer.create(mtl_ctx, idx_data.len, idx_data.ptr);
            if (!metal_buffer.isValid(&index_buf)) {
                logger.err("Failed to create Metal index buffer", .{});
                metal_buffer.destroy(&gpu_data.metal.vertex_buffer);
                return false;
            }
            gpu_data.metal.index_buffer = index_buf;
        }

        return true;
    }

    fn destroyGpuBuffers(self: *GeometrySystem, gpu_data: *GeometryGpuData) void {
        _ = self;

        const render_sys = renderer.getSystem() orelse return;

        switch (render_sys.backend) {
            .vulkan => |*v| {
                const vk_ctx = &v.context;
                // Wait for GPU to finish using buffers
                if (vk_ctx.device != null) {
                    _ = vk.vkDeviceWaitIdle(vk_ctx.device);
                }
                switch (gpu_data.*) {
                    .vulkan => |*vk_data| {
                        vk_buffer.destroy(vk_ctx, &vk_data.vertex_buffer);
                        vk_buffer.destroy(vk_ctx, &vk_data.index_buffer);
                    },
                    else => {},
                }
            },
            .metal => {
                switch (gpu_data.*) {
                    .metal => |*mtl_data| {
                        metal_buffer.destroy(&mtl_data.vertex_buffer);
                        metal_buffer.destroy(&mtl_data.index_buffer);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn computeBoundingBox(self: *GeometrySystem, entry: *GeometryEntry, config: GeometryConfig) void {
        _ = self;

        if (config.vertices == null or config.vertex_count == 0) return;

        var min_pos: [3]f32 = .{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
        var max_pos: [3]f32 = .{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };

        // Iterate through vertices based on format
        const stride = config.vertex_format.getStride();
        const vertices_bytes: [*]const u8 = @ptrCast(config.vertices.?);

        for (0..config.vertex_count) |i| {
            const offset = i * stride;
            const pos_ptr: *const [3]f32 = @ptrCast(@alignCast(vertices_bytes + offset));
            const pos = pos_ptr.*;

            min_pos[0] = @min(min_pos[0], pos[0]);
            min_pos[1] = @min(min_pos[1], pos[1]);
            min_pos[2] = @min(min_pos[2], pos[2]);
            max_pos[0] = @max(max_pos[0], pos[0]);
            max_pos[1] = @max(max_pos[1], pos[1]);
            max_pos[2] = @max(max_pos[2], pos[2]);
        }

        entry.geometry.bounding_min = min_pos;
        entry.geometry.bounding_max = max_pos;

        // Compute center and radius
        entry.geometry.bounding_center = .{
            (min_pos[0] + max_pos[0]) / 2.0,
            (min_pos[1] + max_pos[1]) / 2.0,
            (min_pos[2] + max_pos[2]) / 2.0,
        };

        const dx = max_pos[0] - min_pos[0];
        const dy = max_pos[1] - min_pos[1];
        const dz = max_pos[2] - min_pos[2];
        entry.geometry.bounding_radius = @sqrt(dx * dx + dy * dy + dz * dz) / 2.0;
    }

    fn allocateId(self: *GeometrySystem) ?u32 {
        // First try using next_id if it's still valid
        if (self.next_id <= MAX_GEOMETRIES) {
            const id = self.next_id;
            self.next_id += 1;
            return id;
        }

        // Otherwise, find a free slot
        for (self.geometries, 0..) |entry, i| {
            if (!entry.is_valid) {
                return @intCast(i + 1);
            }
        }

        return null; // No free slots
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Get file extension from a path (without the dot)
fn getFileExtension(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '.') {
            return path[i + 1 ..];
        }
        if (path[i] == '/' or path[i] == '\\') {
            break;
        }
    }
    return "";
}

/// Get filename from a path (without directory and extension)
fn getFileName(path: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = path.len;

    // Find start (after last separator)
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') {
            start = i + 1;
            break;
        }
    }

    // Find end (before extension)
    i = path.len;
    while (i > start) {
        i -= 1;
        if (path[i] == '.') {
            end = i;
            break;
        }
    }

    return path[start..end];
}

// ============================================================================
// Module-Level Convenience Functions
// ============================================================================

/// Get the geometry system instance
pub fn getSystem() ?*GeometrySystem {
    return context.get().geometry;
}

pub fn acquireFromConfig(config: GeometryConfig) ?*Geometry {
    const sys = getSystem() orelse return null;
    return sys.acquireFromConfig(config);
}

pub fn acquire(name: []const u8) ?*Geometry {
    const sys = getSystem() orelse return null;
    return sys.acquire(name);
}

pub fn acquireById(id: u32) ?*Geometry {
    const sys = getSystem() orelse return null;
    return sys.acquireById(id);
}

pub fn release(id: u32) void {
    if (getSystem()) |sys| {
        sys.release(id);
    }
}

pub fn getGeometry(id: u32) ?*Geometry {
    const sys = getSystem() orelse return null;
    return sys.getGeometry(id);
}

pub fn getDefault() ?*Geometry {
    const sys = getSystem() orelse return null;
    return sys.getDefault();
}

pub fn getDefaultId() u32 {
    const sys = getSystem() orelse return INVALID_GEOMETRY_ID;
    return sys.getDefaultId();
}

pub fn generatePlane(config: PlaneConfig) ?*Geometry {
    const sys = getSystem() orelse {
        logger.err("CRITICAL: GeometrySystem not available in context when generating plane", .{});
        logger.err("  Context ptr: {*}, geometry field: {*}", .{ context.get(), context.get().geometry });
        return null;
    };
    const result = sys.generatePlane(config);
    if (result) |geo| {
        logger.debug("[GEOMETRY] generatePlane returned geometry with ID: {}", .{geo.id});
    }
    return result;
}

pub fn generateCube(config: CubeConfig) ?*Geometry {
    const sys = getSystem() orelse {
        logger.err("CRITICAL: GeometrySystem not available in context when generating cube", .{});
        logger.err("  Context ptr: {*}, geometry field: {*}", .{ context.get(), context.get().geometry });
        return null;
    };
    const result = sys.generateCube(config);
    if (result) |geo| {
        logger.debug("[GEOMETRY] generateCube returned geometry with ID: {}", .{geo.id});
    }
    return result;
}

pub fn generateSphere(config: SphereConfig) ?*Geometry {
    const sys = getSystem() orelse {
        logger.err("CRITICAL: GeometrySystem not available in context when generating sphere", .{});
        logger.err("  Context ptr: {*}, geometry field: {*}", .{ context.get(), context.get().geometry });
        return null;
    };
    const result = sys.generateSphere(config);
    if (result) |geo| {
        logger.debug("[GEOMETRY] generateSphere returned geometry with ID: {}", .{geo.id});
    }
    return result;
}

pub fn generateCylinder(config: CylinderConfig) ?*Geometry {
    const sys = getSystem() orelse return null;
    return sys.generateCylinder(config);
}

pub fn generateCone(config: ConeConfig) ?*Geometry {
    const sys = getSystem() orelse return null;
    return sys.generateCone(config);
}
