//! MeshAssetSystem - Manages mesh assets with ID-based registry and GPU lifecycle.
//!
//! Provides:
//! - Auto-incrementing mesh IDs with generation counters
//! - Name-based mesh cache/lookup
//! - Reference counting for meshes
//! - Default mesh management (quad fallback)
//! - GPU buffer management (Vulkan/Metal)
//! - Async loading with job system integration
//! - Integration with MeshBuilder for CPU-side construction
//!
//! Mirrors MaterialSystem and GeometrySystem patterns for consistency.

const std = @import("std");
const builtin = @import("builtin");
const context = @import("../context.zig");
const logger = @import("../core/logging.zig");
const mesh_asset_types = @import("../resources/mesh_asset_types.zig");
const mesh_builder_mod = @import("mesh_builder.zig");
const math_types = @import("../math/types.zig");
const math = @import("../math/math.zig");
const renderer = @import("../renderer/renderer.zig");
const vk_buffer = @import("../renderer/vulkan/buffer.zig");
const vk_context = @import("../renderer/vulkan/context.zig");
const vk = vk_context.vk;
const metal_buffer = @import("../renderer/metal/buffer.zig");
const metal_context = @import("../renderer/metal/context.zig");
const jobs = @import("jobs.zig");

// Import types
const MeshAsset = mesh_asset_types.MeshAsset;
const MeshGpuData = mesh_asset_types.MeshGpuData;
const Submesh = mesh_asset_types.Submesh;
const IndexType = mesh_asset_types.IndexType;
const VertexLayout = mesh_asset_types.VertexLayout;
const MeshBuilder = mesh_builder_mod.MeshBuilder;

// ============================================================================
// Constants
// ============================================================================

/// Invalid mesh asset ID constant
pub const INVALID_MESH_ASSET_ID: u32 = 0;

/// Maximum number of mesh assets that can be registered
pub const MAX_MESH_ASSETS: usize = 512;

/// Maximum length for mesh asset names
pub const MESH_ASSET_NAME_MAX_LENGTH: u32 = 256;

/// Default mesh asset name
pub const DEFAULT_MESH_ASSET_NAME: []const u8 = "default_quad";

// ============================================================================
// MeshAssetEntry
// ============================================================================

/// Mesh asset entry in the registry
const MeshAssetEntry = struct {
    mesh_asset: MeshAsset = .{},
    name: ?[]const u8 = null, // heap-allocated for lookup
    ref_count: u32 = 0,
    is_valid: bool = false,
    auto_release: bool = true,

    // GPU data stored inline (optional until buffers are created)
    gpu_data: ?MeshGpuData = null,
};

// ============================================================================
// MeshAssetSystem
// ============================================================================

// Private instance storage
var instance: MeshAssetSystem = undefined;

pub const MeshAssetSystem = struct {
    /// Mesh asset registry - index is mesh ID - 1 (ID 0 is invalid)
    mesh_assets: [MAX_MESH_ASSETS]MeshAssetEntry,

    /// Name to mesh asset ID lookup (for caching)
    name_lookup: std.StringHashMap(u32),

    /// Next available mesh asset ID
    next_id: u32,

    /// Default mesh asset ID (quad for fallback)
    default_mesh_asset_id: u32,

    /// Statistics
    total_vertex_count: u64,
    total_index_count: u64,
    total_submesh_count: u64,

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /// Initialize the mesh asset system (called after renderer)
    pub fn initialize() bool {
        instance = MeshAssetSystem{
            .mesh_assets = [_]MeshAssetEntry{.{}} ** MAX_MESH_ASSETS,
            .name_lookup = std.StringHashMap(u32).init(std.heap.page_allocator),
            .next_id = 1, // Start at 1, 0 is invalid
            .default_mesh_asset_id = INVALID_MESH_ASSET_ID,
            .total_vertex_count = 0,
            .total_index_count = 0,
            .total_submesh_count = 0,
        };

        // Create default mesh (quad)
        if (!instance.createDefaultMesh()) {
            logger.err("Failed to create default mesh asset", .{});
            return false;
        }

        // Register with engine context
        context.get().mesh_asset = &instance;
        logger.info("MeshAsset system initialized.", .{});
        return true;
    }

    /// Shutdown the mesh asset system
    pub fn shutdown() void {
        const sys = context.get().mesh_asset orelse return;

        // Destroy all mesh assets
        for (&sys.mesh_assets) |*entry| {
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
        context.get().mesh_asset = null;
        logger.info("MeshAsset system shutdown.", .{});
    }

    // ========================================================================
    // Public API - Acquisition
    // ========================================================================

    /// Acquire mesh asset from a MeshBuilder
    ///
    /// This creates GPU buffers from the MeshBuilder's CPU-side data
    /// and stores the mesh in the registry.
    pub fn acquireFromBuilder(self: *MeshAssetSystem, builder: *MeshBuilder, name: []const u8) ?*MeshAsset {
        // Check if already exists (cache lookup)
        if (name.len > 0) {
            if (self.name_lookup.get(name)) |existing_id| {
                const idx = existing_id - 1;
                self.mesh_assets[idx].ref_count += 1;
                logger.info("MeshAsset '{s}' acquired from cache (id={}, ref_count={})", .{ name, existing_id, self.mesh_assets[idx].ref_count });
                return &self.mesh_assets[idx].mesh_asset;
            }
        }

        // Allocate new ID
        const mesh_id = self.allocateId() orelse {
            logger.err("Failed to allocate mesh asset ID (max={} reached)", .{MAX_MESH_ASSETS});
            return null;
        };

        const idx = mesh_id - 1;
        const entry = &self.mesh_assets[idx];

        // Initialize mesh asset
        entry.mesh_asset = .{
            .id = mesh_id,
            .generation = 0,
            .vertex_count = @intCast(builder.vertices.items.len),
            .index_count = @intCast(builder.indices.items.len),
            .index_type = builder.index_type,
            .vertex_layout = .vertex3d,
            .submesh_count = builder.submesh_count,
            .bounding_min = builder.bounding_min,
            .bounding_max = builder.bounding_max,
            .bounding_center = builder.bounding_center,
            .bounding_radius = builder.bounding_radius,
        };

        // Copy submeshes
        for (0..builder.submesh_count) |i| {
            entry.mesh_asset.submeshes[i] = builder.submeshes[i];
        }

        // Create GPU buffers
        const vertices_bytes = std.mem.sliceAsBytes(builder.vertices.items);
        const indices_bytes = if (builder.indices.items.len > 0)
            std.mem.sliceAsBytes(builder.indices.items)
        else
            null;

        entry.gpu_data = MeshGpuData{ .vulkan = .{} }; // Placeholder, will be set in createGpuBuffers
        if (!self.createGpuBuffers(&entry.gpu_data.?, vertices_bytes, indices_bytes)) {
            logger.err("Failed to create GPU buffers for mesh asset '{s}'", .{name});
            return null;
        }

        entry.mesh_asset.gpu_data = &entry.gpu_data.?;

        // Store name
        if (name.len > 0) {
            const name_copy = std.heap.page_allocator.dupe(u8, name) catch {
                logger.err("Failed to allocate name for mesh asset", .{});
                self.destroyGpuBuffers(&entry.gpu_data.?);
                return null;
            };
            entry.name = name_copy;
            self.name_lookup.put(name_copy, mesh_id) catch {
                logger.err("Failed to add mesh asset to name lookup", .{});
                std.heap.page_allocator.free(name_copy);
                self.destroyGpuBuffers(&entry.gpu_data.?);
                return null;
            };
        }

        // Finalize entry
        entry.ref_count = 1;
        entry.is_valid = true;
        entry.auto_release = true;

        // Update statistics
        self.total_vertex_count += entry.mesh_asset.vertex_count;
        self.total_index_count += entry.mesh_asset.index_count;
        self.total_submesh_count += entry.mesh_asset.submesh_count;

        logger.info("MeshAsset '{s}' created (id={}, vertices={}, indices={}, submeshes={})", .{
            name,
            mesh_id,
            entry.mesh_asset.vertex_count,
            entry.mesh_asset.index_count,
            entry.mesh_asset.submesh_count,
        });

        return &entry.mesh_asset;
    }

    /// Acquire mesh asset by name (cache lookup only)
    ///
    /// Returns null if not found. Use acquireFromBuilder to create new meshes.
    pub fn acquire(self: *MeshAssetSystem, name: []const u8) ?*MeshAsset {
        const mesh_id = self.name_lookup.get(name) orelse return null;
        const idx = mesh_id - 1;

        if (!self.mesh_assets[idx].is_valid) return null;

        self.mesh_assets[idx].ref_count += 1;
        logger.info("MeshAsset '{s}' acquired (id={}, ref_count={})", .{ name, mesh_id, self.mesh_assets[idx].ref_count });

        return &self.mesh_assets[idx].mesh_asset;
    }

    /// Release a mesh asset (decrement ref count, destroy if zero)
    pub fn release(self: *MeshAssetSystem, id: u32) void {
        if (id == 0 or id > MAX_MESH_ASSETS) return;

        const idx = id - 1;
        const entry = &self.mesh_assets[idx];

        if (!entry.is_valid) return;

        // Decrement ref count
        if (entry.ref_count > 0) {
            entry.ref_count -= 1;
        }

        logger.info("MeshAsset released (id={}, ref_count={})", .{ id, entry.ref_count });

        // Destroy if ref count reaches zero and auto-release is enabled
        if (entry.ref_count == 0 and entry.auto_release) {
            self.destroyMeshAsset(id);
        }
    }

    /// Get mesh asset by ID (returns null if invalid)
    pub fn getMesh(self: *MeshAssetSystem, id: u32) ?*MeshAsset {
        if (id == 0 or id > MAX_MESH_ASSETS) return null;

        const idx = id - 1;
        if (!self.mesh_assets[idx].is_valid) return null;

        return &self.mesh_assets[idx].mesh_asset;
    }

    /// Get the default mesh asset (quad)
    pub fn getDefault(self: *MeshAssetSystem) ?*MeshAsset {
        return self.getMesh(self.default_mesh_asset_id);
    }

    // ========================================================================
    // Internal Helpers
    // ========================================================================

    /// Allocate a new mesh asset ID
    fn allocateId(self: *MeshAssetSystem) ?u32 {
        const start_id = self.next_id;
        var current_id = start_id;

        // Find next available slot (linear search with wraparound)
        while (true) {
            if (current_id == 0) current_id = 1; // Skip invalid ID

            const idx = current_id - 1;
            if (!self.mesh_assets[idx].is_valid) {
                self.next_id = current_id + 1;
                return current_id;
            }

            current_id += 1;
            if (current_id > MAX_MESH_ASSETS) current_id = 1;

            // Full loop without finding slot
            if (current_id == start_id) return null;
        }
    }

    /// Destroy a mesh asset by ID
    fn destroyMeshAsset(self: *MeshAssetSystem, id: u32) void {
        if (id == 0 or id > MAX_MESH_ASSETS) return;

        const idx = id - 1;
        const entry = &self.mesh_assets[idx];

        if (!entry.is_valid) return;

        // Update statistics
        self.total_vertex_count -= entry.mesh_asset.vertex_count;
        self.total_index_count -= entry.mesh_asset.index_count;
        self.total_submesh_count -= entry.mesh_asset.submesh_count;

        // Destroy GPU buffers
        if (entry.gpu_data) |*gpu_data| {
            self.destroyGpuBuffers(gpu_data);
        }

        // Remove from name lookup
        if (entry.name) |name| {
            _ = self.name_lookup.remove(name);
            std.heap.page_allocator.free(name);
        }

        entry.* = .{}; // Reset to default
        logger.info("MeshAsset destroyed (id={})", .{id});
    }

    /// Create default mesh (quad)
    fn createDefaultMesh(self: *MeshAssetSystem) bool {
        var builder = MeshBuilder.init(std.heap.page_allocator);
        defer builder.deinit();

        // Quad vertices (-0.5 to 0.5 in XY plane)
        const v0 = math_types.Vertex3D{
            .position = .{ -0.5, -0.5, 0.0 },
            .normal = .{ 0.0, 0.0, 1.0 },
            .texcoord = .{ 0.0, 0.0 },
            .tangent = .{ 1.0, 0.0, 0.0, 1.0 },
            .color = .{ 1.0, 1.0, 1.0, 1.0 },
        };
        const v1 = math_types.Vertex3D{
            .position = .{ 0.5, -0.5, 0.0 },
            .normal = .{ 0.0, 0.0, 1.0 },
            .texcoord = .{ 1.0, 0.0 },
            .tangent = .{ 1.0, 0.0, 0.0, 1.0 },
            .color = .{ 1.0, 1.0, 1.0, 1.0 },
        };
        const v2 = math_types.Vertex3D{
            .position = .{ 0.5, 0.5, 0.0 },
            .normal = .{ 0.0, 0.0, 1.0 },
            .texcoord = .{ 1.0, 1.0 },
            .tangent = .{ 1.0, 0.0, 0.0, 1.0 },
            .color = .{ 1.0, 1.0, 1.0, 1.0 },
        };
        const v3 = math_types.Vertex3D{
            .position = .{ -0.5, 0.5, 0.0 },
            .normal = .{ 0.0, 0.0, 1.0 },
            .texcoord = .{ 0.0, 1.0 },
            .tangent = .{ 1.0, 0.0, 0.0, 1.0 },
            .color = .{ 1.0, 1.0, 1.0, 1.0 },
        };

        _ = builder.addVertex(v0) catch return false;
        _ = builder.addVertex(v1) catch return false;
        _ = builder.addVertex(v2) catch return false;
        _ = builder.addVertex(v3) catch return false;

        // Create single submesh
        builder.beginSubmesh("quad") catch return false;
        builder.addTriangle(0, 1, 2) catch return false;
        builder.addTriangle(0, 2, 3) catch return false;
        builder.endSubmesh() catch return false;

        builder.finalize() catch return false;

        const mesh = self.acquireFromBuilder(&builder, DEFAULT_MESH_ASSET_NAME) orelse return false;

        self.default_mesh_asset_id = mesh.id;
        logger.info("Default mesh asset created (id={})", .{self.default_mesh_asset_id});

        return true;
    }

    // ========================================================================
    // GPU Buffer Management
    // ========================================================================

    fn createGpuBuffers(
        self: *MeshAssetSystem,
        gpu_data: *MeshGpuData,
        vertices: []const u8,
        indices: ?[]const u8,
    ) bool {
        _ = self;

        const render_sys = renderer.getSystem() orelse {
            logger.err("Renderer system not available for mesh asset creation", .{});
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
                logger.err("MeshAsset system does not support this backend", .{});
                return false;
            },
        }
    }

    fn createVulkanBuffers(
        vk_ctx: *vk_context.VulkanContext,
        gpu_data: *MeshGpuData,
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
        gpu_data: *MeshGpuData,
        vertices: []const u8,
        indices: ?[]const u8,
    ) bool {
        // Initialize as metal variant
        gpu_data.* = .{ .metal = .{} };

        // Metal uses shared storage, so we can create buffers directly with data
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

    fn destroyGpuBuffers(self: *MeshAssetSystem, gpu_data: *MeshGpuData) void {
        _ = self;

        const render_sys = renderer.getSystem() orelse return;

        switch (render_sys.backend) {
            .vulkan => |*v| {
                vk_buffer.destroy(&v.context, &gpu_data.vulkan.vertex_buffer);
                vk_buffer.destroy(&v.context, &gpu_data.vulkan.index_buffer);
            },
            .metal => {
                metal_buffer.destroy(&gpu_data.metal.vertex_buffer);
                metal_buffer.destroy(&gpu_data.metal.index_buffer);
            },
            else => {},
        }
    }

    // ========================================================================
    // Statistics
    // ========================================================================

    /// Print system statistics
    pub fn printStats(self: *MeshAssetSystem) void {
        var active_count: u32 = 0;
        for (self.mesh_assets) |entry| {
            if (entry.is_valid) active_count += 1;
        }

        logger.info("MeshAsset System Statistics:", .{});
        logger.info("  Active mesh assets: {}/{}", .{ active_count, MAX_MESH_ASSETS });
        logger.info("  Total vertices: {}", .{self.total_vertex_count});
        logger.info("  Total indices: {}", .{self.total_index_count});
        logger.info("  Total submeshes: {}", .{self.total_submesh_count});
        logger.info("  Default mesh ID: {}", .{self.default_mesh_asset_id});
    }
};

// ============================================================================
// Module-Level Accessors
// ============================================================================

/// Get the mesh asset system instance
pub fn getSystem() ?*MeshAssetSystem {
    return context.get().mesh_asset;
}
