//! Resource Registry - Centralized tracking of all resources
//!
//! Provides:
//! - Metadata for all resources (state, dependencies, file paths)
//! - Reference counting
//! - URI-based lookup
//! - Dependency tracking
//! - Job tracking for async operations

const std = @import("std");
const handle = @import("handle.zig");
const jobs = @import("../systems/jobs.zig");

/// Resource loading/runtime state
pub const ResourceState = enum(u8) {
    unloaded, // Not yet requested
    loading, // Async load in progress
    loaded, // Successfully loaded
    failed, // Load failed
    hot_reloading, // Hot-reload in progress

    pub fn toString(self: ResourceState) []const u8 {
        return switch (self) {
            .unloaded => "unloaded",
            .loading => "loading",
            .loaded => "loaded",
            .failed => "failed",
            .hot_reloading => "hot_reloading",
        };
    }
};

/// Metadata for a single resource
pub const ResourceMetadata = struct {
    /// Unique identifier (path or name)
    uri: []const u8,

    /// Resource type
    resource_type: handle.ResourceType,

    /// Current state
    state: ResourceState,

    /// ID in the specific system (TextureSystem, MaterialSystem, etc.)
    /// This is the actual texture ID, material ID, etc.
    system_id: u32,

    /// Generation counter for handle validation
    generation: u32,

    /// Reference count
    ref_count: u32,

    /// Dependencies (metadata IDs of resources this depends on)
    dependencies: std.ArrayList(u32),

    /// Dependents (metadata IDs of resources that depend on this)
    dependents: std.ArrayList(u32),

    /// File path (null for programmatic resources)
    file_path: ?[]const u8,

    /// Last modified timestamp (from stat)
    last_modified: i128,

    /// Hot-reload callback (optional)
    hot_reload_callback: ?*const fn (u32) void,

    /// Job handle for async loading (if loading)
    load_job: ?jobs.JobHandle,

    /// Allocator used for this metadata
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        uri: []const u8,
        resource_type: handle.ResourceType,
    ) !ResourceMetadata {
        const uri_copy = try allocator.dupe(u8, uri);
        errdefer allocator.free(uri_copy);

        return ResourceMetadata{
            .uri = uri_copy,
            .resource_type = resource_type,
            .state = .unloaded,
            .system_id = 0,
            .generation = 0,
            .ref_count = 0,
            .dependencies = .empty,
            .dependents = .empty,
            .file_path = null,
            .last_modified = 0,
            .hot_reload_callback = null,
            .load_job = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResourceMetadata) void {
        self.allocator.free(self.uri);
        if (self.file_path) |path| {
            self.allocator.free(path);
        }
        self.dependencies.deinit(
            self.allocator,
        );
        self.dependents.deinit(
            self.allocator,
        );
    }

    pub fn setFilePath(self: *ResourceMetadata, path: []const u8) !void {
        if (self.file_path) |old_path| {
            self.allocator.free(old_path);
        }
        self.file_path = try self.allocator.dupe(u8, path);
    }

    pub fn acquire(self: *ResourceMetadata) void {
        self.ref_count += 1;
    }

    pub fn release(self: *ResourceMetadata) u32 {
        if (self.ref_count > 0) {
            self.ref_count -= 1;
        }
        return self.ref_count;
    }
};

/// Resource Registry - manages all resource metadata
pub const ResourceRegistry = struct {
    /// All resource metadata
    metadata: std.ArrayList(ResourceMetadata),

    /// URI to metadata ID mapping
    uri_to_id: std.StringHashMap(u32),

    /// System ID to metadata ID mapping (per resource type)
    /// Key is (resource_type << 24) | system_id
    system_id_to_metadata_id: std.AutoHashMap(u32, u32),

    /// Next available metadata ID
    next_id: u32,

    /// Allocator
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ResourceRegistry {
        return ResourceRegistry{
            .metadata = .empty,
            .uri_to_id = std.StringHashMap(u32).init(allocator),
            .system_id_to_metadata_id = std.AutoHashMap(u32, u32).init(allocator),
            .next_id = 1, // Start at 1, 0 is invalid
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResourceRegistry) void {
        for (self.metadata.items) |*meta| {
            meta.deinit();
        }
        self.metadata.deinit(self.allocator);
        self.uri_to_id.deinit();
        self.system_id_to_metadata_id.deinit();
    }

    /// Register a new resource
    pub fn register(
        self: *ResourceRegistry,
        uri: []const u8,
        resource_type: handle.ResourceType,
    ) !u32 {
        // Check if already registered
        if (self.uri_to_id.get(uri)) |existing_id| {
            return existing_id;
        }

        const metadata_id = self.next_id;
        self.next_id += 1;

        var meta = try ResourceMetadata.init(self.allocator, uri, resource_type);
        errdefer meta.deinit();

        try self.metadata.append(self.allocator, meta);
        try self.uri_to_id.put(meta.uri, metadata_id);

        return metadata_id;
    }

    /// Unregister a resource
    pub fn unregister(self: *ResourceRegistry, metadata_id: u32) void {
        if (metadata_id == 0 or metadata_id >= self.next_id) return;

        const index = metadata_id - 1;
        if (index >= self.metadata.items.len) return;

        var meta = &self.metadata.items[index];
        _ = self.uri_to_id.remove(meta.uri);

        // Remove from system ID mapping if exists
        if (meta.system_id != 0) {
            const key = self.makeSystemIdKey(meta.resource_type, meta.system_id);
            _ = self.system_id_to_metadata_id.remove(key);
        }

        meta.deinit();
    }

    /// Find resource by URI
    pub fn findByUri(self: *ResourceRegistry, uri: []const u8) ?u32 {
        return self.uri_to_id.get(uri);
    }

    /// Find resource by system ID
    pub fn findBySystemId(
        self: *ResourceRegistry,
        resource_type: handle.ResourceType,
        system_id: u32,
    ) ?u32 {
        const key = self.makeSystemIdKey(resource_type, system_id);
        return self.system_id_to_metadata_id.get(key);
    }

    /// Get metadata by ID
    pub fn get(self: *ResourceRegistry, metadata_id: u32) ?*ResourceMetadata {
        if (metadata_id == 0 or metadata_id >= self.next_id) return null;
        const index = metadata_id - 1;
        if (index >= self.metadata.items.len) return null;
        return &self.metadata.items[index];
    }

    /// Link metadata to system ID
    pub fn linkSystemId(
        self: *ResourceRegistry,
        metadata_id: u32,
        system_id: u32,
    ) !void {
        if (metadata_id == 0) {
            return error.InvalidMetadataId;
        }

        const meta = self.get(metadata_id) orelse return error.MetadataNotFound;
        meta.system_id = system_id;

        const key = self.makeSystemIdKey(meta.resource_type, system_id);
        try self.system_id_to_metadata_id.put(key, metadata_id);
    }

    /// Add dependency relationship
    pub fn addDependency(
        self: *ResourceRegistry,
        dependent_id: u32,
        dependency_id: u32,
    ) !void {
        const dependent = self.get(dependent_id) orelse return error.DependentNotFound;
        const dependency = self.get(dependency_id) orelse return error.DependencyNotFound;

        // Add to dependent's dependencies list
        try dependent.dependencies.append(dependency_id);

        // Add to dependency's dependents list
        try dependency.dependents.append(dependent_id);
    }

    /// Remove dependency relationship
    pub fn removeDependency(
        self: *ResourceRegistry,
        dependent_id: u32,
        dependency_id: u32,
    ) void {
        const dependent = self.get(dependent_id) orelse return;
        const dependency = self.get(dependency_id) orelse return;

        // Remove from dependent's dependencies list
        for (dependent.dependencies.items, 0..) |dep_id, i| {
            if (dep_id == dependency_id) {
                _ = dependent.dependencies.swapRemove(i);
                break;
            }
        }

        // Remove from dependency's dependents list
        for (dependency.dependents.items, 0..) |dep_id, i| {
            if (dep_id == dependent_id) {
                _ = dependency.dependents.swapRemove(i);
                break;
            }
        }
    }

    /// Get all dependencies of a resource (direct)
    pub fn getDependencies(
        self: *ResourceRegistry,
        metadata_id: u32,
        allocator: std.mem.Allocator,
    ) ![]u32 {
        const meta = self.get(metadata_id) orelse return error.MetadataNotFound;
        return try allocator.dupe(u32, meta.dependencies.items);
    }

    /// Get all dependents of a resource (direct)
    pub fn getDependents(
        self: *ResourceRegistry,
        metadata_id: u32,
        allocator: std.mem.Allocator,
    ) ![]u32 {
        const meta = self.get(metadata_id) orelse return error.MetadataNotFound;
        return try allocator.dupe(u32, meta.dependents.items);
    }

    // Internal helpers

    fn makeSystemIdKey(self: *ResourceRegistry, resource_type: handle.ResourceType, system_id: u32) u32 {
        _ = self;
        const type_bits: u32 = @intFromEnum(resource_type);
        return (type_bits << 24) | system_id;
    }
};

// Tests
const testing = std.testing;

test "ResourceRegistry: basic operations" {
    var registry = ResourceRegistry.init(testing.allocator);
    defer registry.deinit();

    // Register a texture
    const tex_id = try registry.register("textures/brick.png", .texture);
    try testing.expect(tex_id > 0);

    // Find by URI
    const found_id = registry.findByUri("textures/brick.png");
    try testing.expect(found_id != null);
    try testing.expectEqual(tex_id, found_id.?);

    // Get metadata
    const meta = registry.get(tex_id);
    try testing.expect(meta != null);
    try testing.expectEqual(handle.ResourceType.texture, meta.?.resource_type);
    try testing.expectEqual(ResourceState.unloaded, meta.?.state);
}

test "ResourceRegistry: system ID linking" {
    var registry = ResourceRegistry.init(testing.allocator);
    defer registry.deinit();

    const tex_id = try registry.register("textures/wall.png", .texture);
    try registry.linkSystemId(tex_id, 42);

    // Find by system ID
    const found_id = registry.findBySystemId(.texture, 42);
    try testing.expect(found_id != null);
    try testing.expectEqual(tex_id, found_id.?);

    // Wrong type should not find
    const wrong_type = registry.findBySystemId(.material, 42);
    try testing.expect(wrong_type == null);
}

test "ResourceRegistry: dependencies" {
    var registry = ResourceRegistry.init(testing.allocator);
    defer registry.deinit();

    const tex_id = try registry.register("textures/brick.png", .texture);
    const mat_id = try registry.register("materials/brick", .material);

    // Material depends on texture
    try registry.addDependency(mat_id, tex_id);

    // Check dependencies
    const deps = try registry.getDependencies(mat_id, testing.allocator);
    defer testing.allocator.free(deps);

    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expectEqual(tex_id, deps[0]);

    // Check dependents
    const dependents = try registry.getDependents(tex_id, testing.allocator);
    defer testing.allocator.free(dependents);

    try testing.expectEqual(@as(usize, 1), dependents.len);
    try testing.expectEqual(mat_id, dependents[0]);
}

test "ResourceMetadata: reference counting" {
    var meta = try ResourceMetadata.init(testing.allocator, "test_resource", .texture);
    defer meta.deinit();

    try testing.expectEqual(@as(u32, 0), meta.ref_count);

    meta.acquire();
    try testing.expectEqual(@as(u32, 1), meta.ref_count);

    meta.acquire();
    try testing.expectEqual(@as(u32, 2), meta.ref_count);

    const count = meta.release();
    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(@as(u32, 1), meta.ref_count);
}
