//! Resource Manager - Unified API for all resource operations
//!
//! Provides:
//! - High-level resource loading API
//! - Automatic dependency tracking
//! - Batch loading support
//! - Integration with all resource systems
//! - Job system integration for async operations

const std = @import("std");
const context = @import("../context.zig");
const logger = @import("../core/logging.zig");
const jobs = @import("../systems/jobs.zig");
const texture = @import("../systems/texture.zig");
const material = @import("../systems/material.zig");
const geometry = @import("../systems/geometry.zig");
const mesh_asset = @import("../systems/mesh_asset.zig");
const memory = @import("../systems/memory.zig");
const handle = @import("handle.zig");
const registry = @import("registry.zig");
const dependency_graph = @import("dependency_graph.zig");

/// Resource Manager - provides unified resource loading API
pub const ResourceManager = struct {
    /// Resource registry for metadata tracking
    resource_registry: registry.ResourceRegistry,

    /// Dependency graph for relationship tracking
    dep_graph: dependency_graph.DependencyGraph,

    /// Allocator
    allocator: std.mem.Allocator,

    /// Initialize the resource manager
    pub fn init(allocator: std.mem.Allocator) bool {
        var reg = registry.ResourceRegistry.init(allocator);

        instance = memory.allocate(ResourceManager, .resource_system);
        instance.?.* = ResourceManager{
            .resource_registry = reg,
            .dep_graph = dependency_graph.DependencyGraph.init(&reg),
            .allocator = allocator,
        };
        context.get().resource_manager = instance;
        logger.info("Resource Manager System initialized.", .{});
        return true;
    }

    /// Shutdown the resource manager
    pub fn deinit(self: *ResourceManager) void {
        self.resource_registry.deinit();
        logger.info("Resource Manager System shutdown.", .{});
    }

    // ========== Synchronous Loading API ==========

    /// Load a texture synchronously
    pub fn loadTexture(self: *ResourceManager, path: []const u8) !handle.TextureHandle {
        // Register in registry
        const metadata_id = try self.resource_registry.register(path, .texture);

        // Load through texture system
        const tex_id = texture.loadFromFile(path);
        if (tex_id == texture.INVALID_TEXTURE_ID) {
            return error.TextureLoadFailed;
        }

        // Link system ID to metadata
        try self.resource_registry.linkSystemId(metadata_id, tex_id);

        // Update state
        if (self.resource_registry.get(metadata_id)) |meta| {
            meta.state = .loaded;
            meta.system_id = tex_id;
        }

        return handle.TextureHandle{
            .id = tex_id,
            .generation = 0,
        };
    }

    /// Load a material synchronously (may load dependent textures)
    pub fn loadMaterial(self: *ResourceManager, name: []const u8) !handle.MaterialHandle {
        // Register in registry
        const metadata_id = try self.resource_registry.register(name, .material);

        // Load through material system (this may load textures internally)
        const mat = material.acquire(name) orelse return error.MaterialLoadFailed;

        // Link system ID to metadata
        try self.resource_registry.linkSystemId(metadata_id, mat.id);

        // Update state
        if (self.resource_registry.get(metadata_id)) |meta| {
            meta.state = .loaded;
            meta.system_id = mat.id;
        }

        return handle.MaterialHandle{
            .id = mat.id,
            .generation = mat.generation,
        };
    }

    /// Load geometry synchronously
    /// DEPRECATED: Use loadMeshAsset() with MeshBuilder instead
    pub fn loadGeometry(self: *ResourceManager, path: []const u8) !handle.GeometryHandle {
        // Register in registry
        const metadata_id = try self.resource_registry.register(path, .geometry);

        // Load through geometry system
        const geom = geometry.acquire(path) orelse return error.GeometryLoadFailed;

        // Link system ID to metadata
        try self.resource_registry.linkSystemId(metadata_id, geom.id);

        // Update state
        if (self.resource_registry.get(metadata_id)) |meta| {
            meta.state = .loaded;
            meta.system_id = geom.id;
        }

        return handle.GeometryHandle{
            .id = geom.id,
            .generation = geom.generation,
        };
    }

    // ========== Procedural Geometry Generation ==========
    // DEPRECATED: These will be replaced with MeshBuilder-based generators

    /// Generate a cube geometry synchronously
    /// DEPRECATED: Use MeshBuilder to create procedural meshes instead
    pub fn loadGeometryCube(self: *ResourceManager, config: geometry.CubeConfig) !handle.GeometryHandle {
        // Register in registry using the config name
        const metadata_id = try self.resource_registry.register(config.name, .geometry);

        // Generate through geometry system
        const geom = geometry.generateCube(config) orelse return error.GeometryGenerationFailed;

        // Link system ID to metadata
        try self.resource_registry.linkSystemId(metadata_id, geom.id);

        // Update state
        if (self.resource_registry.get(metadata_id)) |meta| {
            meta.state = .loaded;
            meta.system_id = geom.id;
        }

        return handle.GeometryHandle{
            .id = geom.id,
            .generation = geom.generation,
        };
    }

    /// Generate a sphere geometry synchronously
    /// DEPRECATED: Use MeshBuilder to create procedural meshes instead
    pub fn loadGeometrySphere(self: *ResourceManager, config: geometry.SphereConfig) !handle.GeometryHandle {
        // Register in registry using the config name
        const metadata_id = try self.resource_registry.register(config.name, .geometry);

        // Generate through geometry system
        const geom = geometry.generateSphere(config) orelse return error.GeometryGenerationFailed;

        // Link system ID to metadata
        try self.resource_registry.linkSystemId(metadata_id, geom.id);

        // Update state
        if (self.resource_registry.get(metadata_id)) |meta| {
            meta.state = .loaded;
            meta.system_id = geom.id;
        }

        return handle.GeometryHandle{
            .id = geom.id,
            .generation = geom.generation,
        };
    }

    /// Generate a plane geometry synchronously
    /// DEPRECATED: Use MeshBuilder to create procedural meshes instead
    pub fn loadGeometryPlane(self: *ResourceManager, config: geometry.PlaneConfig) !handle.GeometryHandle {
        // Register in registry using the config name
        const metadata_id = try self.resource_registry.register(config.name, .geometry);

        // Generate through geometry system
        const geom = geometry.generatePlane(config) orelse return error.GeometryGenerationFailed;

        // Link system ID to metadata
        try self.resource_registry.linkSystemId(metadata_id, geom.id);

        // Update state
        if (self.resource_registry.get(metadata_id)) |meta| {
            meta.state = .loaded;
            meta.system_id = geom.id;
        }

        return handle.GeometryHandle{
            .id = geom.id,
            .generation = geom.generation,
        };
    }

    // ========== MeshAsset Loading ==========

    /// Load mesh asset (cache lookup only)
    /// Note: Use MeshBuilder with acquireFromBuilder for new meshes
    pub fn loadMeshAsset(self: *ResourceManager, name: []const u8) !handle.MeshAssetHandle {
        // Register in registry
        const metadata_id = try self.resource_registry.register(name, .mesh_asset);

        // Try to acquire from cache
        const mesh_sys = mesh_asset.getSystem() orelse return error.MeshAssetSystemNotInitialized;
        const mesh = mesh_sys.acquire(name) orelse return error.MeshAssetNotFound;

        // Link system ID to metadata
        try self.resource_registry.linkSystemId(metadata_id, mesh.id);

        // Update state
        if (self.resource_registry.get(metadata_id)) |meta| {
            meta.state = .loaded;
            meta.system_id = mesh.id;
        }

        return handle.MeshAssetHandle{
            .id = mesh.id,
            .generation = mesh.generation,
        };
    }

    // ========== Asynchronous Loading API ==========

    /// Load texture asynchronously
    pub fn loadTextureAsync(
        self: *ResourceManager,
        path: []const u8,
        callback: ?*const fn (handle.TextureHandle) void,
    ) !jobs.JobHandle {
        // Register in registry
        const metadata_id = try self.resource_registry.register(path, .texture);

        // Mark as loading
        if (self.resource_registry.get(metadata_id)) |meta| {
            meta.state = .loading;
        }

        // Define callback args struct type
        const CallbackArgs = struct {
            metadata_id: u32,
            user_callback: ?*const fn (handle.TextureHandle) void,
        };

        // Create static wrapper
        const Wrapper = struct {
            var saved_args: CallbackArgs = undefined;

            fn onLoaded(tex_id: u32) void {
                const sys = getSystem() orelse return;

                // Update metadata
                if (sys.resource_registry.get(saved_args.metadata_id)) |meta| {
                    if (tex_id != texture.INVALID_TEXTURE_ID) {
                        meta.state = .loaded;
                        meta.system_id = tex_id;
                        sys.resource_registry.linkSystemId(saved_args.metadata_id, tex_id) catch {};
                    } else {
                        meta.state = .failed;
                    }
                }

                // Call user callback
                if (saved_args.user_callback) |cb| {
                    cb(handle.TextureHandle{
                        .id = tex_id,
                        .generation = 0,
                    });
                }
            }
        };

        // Save args
        Wrapper.saved_args = .{
            .metadata_id = metadata_id,
            .user_callback = callback,
        };

        // Submit async load
        return texture.loadFromFileAsync(path, .{}, Wrapper.onLoaded);
    }

    /// Load material asynchronously
    pub fn loadMaterialAsync(
        self: *ResourceManager,
        name: []const u8,
        callback: ?*const fn (handle.MaterialHandle) void,
    ) !jobs.JobHandle {
        // Register in registry
        const metadata_id = try self.resource_registry.register(name, .material);

        // Mark as loading
        if (self.resource_registry.get(metadata_id)) |meta| {
            meta.state = .loading;
        }

        // Define callback args struct type
        const CallbackArgs = struct {
            metadata_id: u32,
            user_callback: ?*const fn (handle.MaterialHandle) void,
        };

        // Create static wrapper
        const Wrapper = struct {
            var saved_args: CallbackArgs = undefined;

            fn onLoaded(mat: ?*@import("../resources/types.zig").Material) void {
                const sys = getSystem() orelse return;

                // Update metadata
                if (sys.resource_registry.get(saved_args.metadata_id)) |meta| {
                    if (mat) |m| {
                        meta.state = .loaded;
                        meta.system_id = m.id;
                        sys.resource_registry.linkSystemId(saved_args.metadata_id, m.id) catch {};
                    } else {
                        meta.state = .failed;
                    }
                }

                // Call user callback
                if (saved_args.user_callback) |cb| {
                    if (mat) |m| {
                        cb(handle.MaterialHandle{
                            .id = m.id,
                            .generation = m.generation,
                        });
                    } else {
                        cb(handle.MaterialHandle.invalid);
                    }
                }
            }
        };

        // Save args
        Wrapper.saved_args = .{
            .metadata_id = metadata_id,
            .user_callback = callback,
        };

        return material.acquireAsync(name, Wrapper.onLoaded);
    }

    /// Load geometry asynchronously
    /// DEPRECATED: Use loadMeshAsset() with MeshBuilder instead
    pub fn loadGeometryAsync(
        self: *ResourceManager,
        path: []const u8,
        callback: ?*const fn (handle.GeometryHandle) void,
    ) !jobs.JobHandle {
        // Register in registry
        const metadata_id = try self.resource_registry.register(path, .geometry);

        // Mark as loading
        if (self.resource_registry.get(metadata_id)) |meta| {
            meta.state = .loading;
        }

        // Define callback args struct type
        const CallbackArgs = struct {
            metadata_id: u32,
            user_callback: ?*const fn (handle.GeometryHandle) void,
        };

        // Create static wrapper
        const Wrapper = struct {
            var saved_args: CallbackArgs = undefined;

            fn onLoaded(geom: ?*@import("../systems/geometry.zig").Geometry) void {
                const sys = getSystem() orelse return;

                // Update metadata
                if (sys.resource_registry.get(saved_args.metadata_id)) |meta| {
                    if (geom) |g| {
                        meta.state = .loaded;
                        meta.system_id = g.id;
                        sys.resource_registry.linkSystemId(saved_args.metadata_id, g.id) catch {};
                    } else {
                        meta.state = .failed;
                    }
                }

                // Call user callback
                if (saved_args.user_callback) |cb| {
                    if (geom) |g| {
                        cb(handle.GeometryHandle{
                            .id = g.id,
                            .generation = g.generation,
                        });
                    } else {
                        cb(handle.GeometryHandle.invalid);
                    }
                }
            }
        };

        // Save args
        Wrapper.saved_args = .{
            .metadata_id = metadata_id,
            .user_callback = callback,
        };

        return geometry.loadFromFileAsync(path, Wrapper.onLoaded);
    }

    // ========== Batch Loading API ==========

    /// Batch load request
    pub const BatchLoadRequest = struct {
        resource_type: handle.ResourceType,
        uri: []const u8,
    };

    /// Batch load multiple resources in parallel
    pub fn loadBatch(
        self: *ResourceManager,
        requests: []const BatchLoadRequest,
        callback: ?*const fn () void,
    ) !jobs.JobHandle {
        _ = self;

        if (requests.len == 0) {
            if (callback) |cb| cb();
            return jobs.INVALID_JOB_HANDLE;
        }

        const jobs_sys = context.get().jobs orelse return error.JobSystemNotInitialized;

        // Create counter for all batch jobs
        const counter = try jobs_sys.counter_pool.allocate();
        counter.init(@intCast(requests.len));

        // Submit each resource load as a job
        for (requests) |request| {
            const BatchJob = struct {
                fn load(args: BatchLoadRequest) void {
                    switch (args.resource_type) {
                        .texture => {
                            _ = texture.loadFromFile(args.uri);
                        },
                        .material => {
                            _ = material.acquire(args.uri);
                        },
                        .geometry => {
                            _ = geometry.acquire(args.uri);
                        },
                        else => {
                            logger.warn("Unsupported resource type in batch load", .{});
                        },
                    }
                }
            };

            try jobs_sys.submitWithCounter(counter, BatchJob.load, request);
        }

        // Submit callback job that runs after all loads complete
        if (callback) |cb| {
            const CallbackJob = struct {
                fn run(args: struct { callback: *const fn () void }) void {
                    args.callback();
                }
            };
            _ = try jobs_sys.submit(CallbackJob.run, .{ .callback = cb });
        }

        return jobs.JobHandle{
            .counter = counter,
            .generation = counter.generation.load(.acquire),
        };
    }

    // ========== Resource Queries ==========

    /// Get metadata for a resource by URI
    pub fn getMetadata(self: *ResourceManager, uri: []const u8) ?*registry.ResourceMetadata {
        const metadata_id = self.resource_registry.findByUri(uri) orelse return null;
        return self.resource_registry.get(metadata_id);
    }

    /// Get resource state by URI
    pub fn getState(self: *ResourceManager, uri: []const u8) registry.ResourceState {
        if (self.getMetadata(uri)) |meta| {
            return meta.state;
        }
        return .unloaded;
    }

    /// Check if resource is loaded
    pub fn isLoaded(self: *ResourceManager, uri: []const u8) bool {
        return self.getState(uri) == .loaded;
    }

    // ========== Dependency Management ==========

    /// Add a dependency relationship
    pub fn addDependency(
        self: *ResourceManager,
        dependent_uri: []const u8,
        dependency_uri: []const u8,
    ) !void {
        const dependent_id = self.resource_registry.findByUri(dependent_uri) orelse return error.DependentNotFound;
        const dependency_id = self.resource_registry.findByUri(dependency_uri) orelse return error.DependencyNotFound;

        try self.dep_graph.addDependency(dependent_id, dependency_id);
    }

    /// Get load order for a resource
    pub fn getLoadOrder(
        self: *ResourceManager,
        uri: []const u8,
    ) ![]u32 {
        const metadata_id = self.resource_registry.findByUri(uri) orelse return error.ResourceNotFound;
        return self.dep_graph.getLoadOrder(metadata_id, self.allocator);
    }
};

/// Module-level singleton instance pointer
var instance: ?*ResourceManager = null;

/// Get the resource manager instance
pub fn getSystem() ?*ResourceManager {
    return instance;
}
