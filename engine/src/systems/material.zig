//! MaterialSystem - Manages material resources with ID-based registry.
//!
//! Provides:
//! - Auto-incrementing material IDs
//! - Name-based material cache/lookup
//! - Reference counting for materials
//! - Default material management
//! - File loading from .bmt config files
//! - Integration with TextureSystem for diffuse maps

const std = @import("std");
const context = @import("../context.zig");
const logger = @import("../core/logging.zig");
const math_types = @import("../math/types.zig");
const filesystem = @import("../platform/filesystem.zig");
const resource_types = @import("../resources/types.zig");
const renderer = @import("../renderer/renderer.zig");
const texture = @import("texture.zig");
const jobs = @import("jobs.zig");

/// Invalid material ID constant
pub const INVALID_MATERIAL_ID: u32 = 0;

/// Maximum number of materials that can be registered
pub const MAX_MATERIALS: usize = 1024;

/// Maximum number of render passes a material can participate in
pub const MAX_MATERIAL_PASSES: usize = 8;

/// Maximum shader path length
pub const MAX_SHADER_PATH_LENGTH: usize = 256;

/// Default material name
pub const DEFAULT_MATERIAL_NAME: []const u8 = "default";

/// Shader info for a specific render pass
pub const PassShaderInfo = struct {
    /// Vertex shader path (relative to assets)
    vertex_shader_path: [MAX_SHADER_PATH_LENGTH]u8 = [_]u8{0} ** MAX_SHADER_PATH_LENGTH,
    /// Fragment shader path (relative to assets)
    fragment_shader_path: [MAX_SHADER_PATH_LENGTH]u8 = [_]u8{0} ** MAX_SHADER_PATH_LENGTH,
    /// Whether this pass has a vertex shader
    has_vertex: bool = false,
    /// Whether this pass has a fragment shader
    has_fragment: bool = false,

    /// Get vertex shader path as slice
    pub fn getVertexPath(self: *const PassShaderInfo) []const u8 {
        return std.mem.sliceTo(&self.vertex_shader_path, 0);
    }

    /// Get fragment shader path as slice
    pub fn getFragmentPath(self: *const PassShaderInfo) []const u8 {
        return std.mem.sliceTo(&self.fragment_shader_path, 0);
    }

    /// Set vertex shader path
    pub fn setVertexPath(self: *PassShaderInfo, path: []const u8) void {
        const copy_len = @min(path.len, MAX_SHADER_PATH_LENGTH - 1);
        @memcpy(self.vertex_shader_path[0..copy_len], path[0..copy_len]);
        self.vertex_shader_path[copy_len] = 0;
        self.has_vertex = path.len > 0;
    }

    /// Set fragment shader path
    pub fn setFragmentPath(self: *PassShaderInfo, path: []const u8) void {
        const copy_len = @min(path.len, MAX_SHADER_PATH_LENGTH - 1);
        @memcpy(self.fragment_shader_path[0..copy_len], path[0..copy_len]);
        self.fragment_shader_path[copy_len] = 0;
        self.has_fragment = path.len > 0;
    }
};

/// Pass name maximum length
pub const MAX_PASS_NAME_LENGTH: usize = 64;

/// Material entry in the registry
const MaterialEntry = struct {
    material: resource_types.Material,
    name: ?[]const u8, // heap-allocated for lookup
    ref_count: u32,
    is_valid: bool,
    auto_release: bool,
    texture_id: u32, // Store texture ID for proper release

    // Multi-pass shader support
    pass_shaders: [MAX_MATERIAL_PASSES]PassShaderInfo = [_]PassShaderInfo{.{}} ** MAX_MATERIAL_PASSES,
    pass_names: [MAX_MATERIAL_PASSES][MAX_PASS_NAME_LENGTH]u8 = [_][MAX_PASS_NAME_LENGTH]u8{[_]u8{0} ** MAX_PASS_NAME_LENGTH} ** MAX_MATERIAL_PASSES,
    pass_count: u8 = 0,

    /// Check if this material participates in a given pass
    pub fn participatesInPass(self: *const MaterialEntry, pass_name: []const u8) bool {
        for (self.pass_names[0..self.pass_count]) |name| {
            const stored_name = std.mem.sliceTo(&name, 0);
            if (std.mem.eql(u8, stored_name, pass_name)) {
                return true;
            }
        }
        return false;
    }

    /// Get shader info for a specific pass
    pub fn getPassShaderInfo(self: *const MaterialEntry, pass_name: []const u8) ?*const PassShaderInfo {
        for (self.pass_names[0..self.pass_count], 0..) |name, i| {
            const stored_name = std.mem.sliceTo(&name, 0);
            if (std.mem.eql(u8, stored_name, pass_name)) {
                return &self.pass_shaders[i];
            }
        }
        return null;
    }

    /// Add a pass to this material
    pub fn addPass(self: *MaterialEntry, pass_name: []const u8, shader_info: PassShaderInfo) bool {
        if (self.pass_count >= MAX_MATERIAL_PASSES) return false;

        const idx = self.pass_count;
        const copy_len = @min(pass_name.len, MAX_PASS_NAME_LENGTH - 1);
        @memcpy(self.pass_names[idx][0..copy_len], pass_name[0..copy_len]);
        self.pass_names[idx][copy_len] = 0;

        self.pass_shaders[idx] = shader_info;
        self.pass_count += 1;
        return true;
    }
};

/// Configuration for creating a material
pub const MaterialConfig = struct {
    name: [resource_types.MATERIAL_NAME_MAX_LENGTH]u8,
    auto_release: bool,
    diffuse_colour: math_types.Vec4,
    diffuse_map_name: [resource_types.TEXTURE_NAME_MAX_LENGTH]u8,
    specular_map_name: [resource_types.TEXTURE_NAME_MAX_LENGTH]u8 = [_]u8{0} ** resource_types.TEXTURE_NAME_MAX_LENGTH,
    specular_color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    shininess: f32 = 32.0,

    // Multi-pass shader configuration
    pass_shaders: [MAX_MATERIAL_PASSES]PassShaderInfo = [_]PassShaderInfo{.{}} ** MAX_MATERIAL_PASSES,
    pass_names: [MAX_MATERIAL_PASSES][MAX_PASS_NAME_LENGTH]u8 = [_][MAX_PASS_NAME_LENGTH]u8{[_]u8{0} ** MAX_PASS_NAME_LENGTH} ** MAX_MATERIAL_PASSES,
    pass_count: u8 = 0,
};

// Private instance storage
var instance: MaterialSystem = undefined;

pub const MaterialSystem = struct {
    /// Material registry - index is material ID - 1 (ID 0 is invalid)
    materials: [MAX_MATERIALS]MaterialEntry,

    /// Name to material ID lookup (for caching)
    name_lookup: std.StringHashMap(u32),

    /// Next available material ID
    next_id: u32,

    /// Default material ID
    default_material_id: u32,

    /// Initialize the material system (called after texture system is initialized)
    pub fn initialize() bool {
        instance = MaterialSystem{
            .materials = [_]MaterialEntry{.{
                .material = .{
                    .id = 0,
                    .generation = 0,
                    .internal_id = 0,
                    .name = [_]u8{0} ** resource_types.MATERIAL_NAME_MAX_LENGTH,
                    .diffuse_colour = .{ .elements = .{ 1.0, 1.0, 1.0, 1.0 } },
                    .diffuse_map = .{
                        .texture = undefined,
                        .use = .TEXTURE_USE_UNKNOWN,
                    },
                    .specular_map = .{
                        .texture = undefined,
                        .use = .TEXTURE_USE_UNKNOWN,
                    },
                    .specular_color = .{ 1.0, 1.0, 1.0 },
                    .shininess = 32.0,
                },
                .name = null,
                .ref_count = 0,
                .is_valid = false,
                .auto_release = false,
                .texture_id = texture.INVALID_TEXTURE_ID,
            }} ** MAX_MATERIALS,
            .name_lookup = std.StringHashMap(u32).init(std.heap.page_allocator),
            .next_id = 1, // Start at 1, 0 is invalid
            .default_material_id = INVALID_MATERIAL_ID,
        };

        // Create default material
        if (!instance.createDefaultMaterial()) {
            logger.err("Failed to create default material", .{});
            return false;
        }

        // Register with engine context
        context.get().material = &instance;
        logger.info("Material system initialized.", .{});
        return true;
    }

    /// Shutdown the material system
    pub fn shutdown() void {
        const sys = context.get().material orelse return;

        // Destroy all materials
        for (&sys.materials) |*entry| {
            if (entry.is_valid) {
                // Release the texture
                if (entry.texture_id != texture.INVALID_TEXTURE_ID) {
                    texture.release(entry.texture_id);
                }
                // Free the name string
                if (entry.name) |name| {
                    std.heap.page_allocator.free(name);
                }
                entry.is_valid = false;
            }
        }

        sys.name_lookup.deinit();
        context.get().material = null;
        logger.info("Material system shutdown.", .{});
    }

    // ========== Public API ==========

    /// Acquire a material by name. Loads from file if not cached.
    /// Returns null on failure.
    pub fn acquire(self: *MaterialSystem, name: []const u8) ?*resource_types.Material {
        // Check cache first
        if (self.name_lookup.get(name)) |existing_id| {
            const idx = existing_id - 1;
            self.materials[idx].ref_count += 1;
            logger.debug("Material cache hit: {s} (id={}, ref_count={})", .{ name, existing_id, self.materials[idx].ref_count });
            return &self.materials[idx].material;
        }

        // Not in cache, try to load from file
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "../assets/materials/{s}.bmt", .{name}) catch {
            logger.err("Material name too long: {s}", .{name});
            return self.getDefaultMaterial();
        };

        const material_id = self.loadFromFile(path);
        if (material_id == INVALID_MATERIAL_ID) {
            logger.warn("Failed to load material '{s}', using default", .{name});
            return self.getDefaultMaterial();
        }

        return self.getMaterial(material_id);
    }

    /// Create a material from a configuration struct.
    /// Returns null on failure.
    pub fn acquireFromConfig(self: *MaterialSystem, config: MaterialConfig) ?*resource_types.Material {
        // Convert fixed array name to slice
        const name_slice = std.mem.sliceTo(&config.name, 0);

        // Check if already exists
        if (self.name_lookup.get(name_slice)) |existing_id| {
            const idx = existing_id - 1;
            self.materials[idx].ref_count += 1;
            logger.debug("Material cache hit (from config): {s} (id={}, ref_count={})", .{ name_slice, existing_id, self.materials[idx].ref_count });
            return &self.materials[idx].material;
        }

        // Allocate new material ID
        const material_id = self.allocateId() orelse {
            logger.err("No free material slots available", .{});
            return null;
        };

        const idx = material_id - 1;
        var entry = &self.materials[idx];

        // Load the diffuse texture
        const diffuse_map_name = std.mem.sliceTo(&config.diffuse_map_name, 0);
        var tex_id: u32 = texture.INVALID_TEXTURE_ID;
        var tex_ptr: ?*resource_types.Texture = null;

        if (diffuse_map_name.len > 0) {
            logger.info("Loading texture for material '{s}': '{s}'", .{ name_slice, diffuse_map_name });
            // Check if file exists
            if (filesystem.exists(diffuse_map_name)) {
                logger.info("Texture file exists: '{s}'", .{diffuse_map_name});
            } else {
                logger.warn("Texture file NOT found: '{s}'", .{diffuse_map_name});
            }
            tex_id = texture.loadFromFile(diffuse_map_name);
            if (tex_id != texture.INVALID_TEXTURE_ID) {
                tex_ptr = texture.getTexture(tex_id);
                logger.info("Texture loaded successfully with ID: {d}", .{tex_id});
            } else {
                logger.warn("Failed to load texture: '{s}'", .{diffuse_map_name});
            }
        }

        // If texture loading failed, use default texture
        if (tex_ptr == null) {
            logger.info("Using default texture for material '{s}'", .{name_slice});
            tex_ptr = texture.getDefaultTexture();
            if (tex_ptr != null) {
                tex_id = texture.INVALID_TEXTURE_ID; // Don't release default texture
            }
        }

        if (tex_ptr == null) {
            logger.err("Failed to get texture for material '{s}'", .{name_slice});
            return null;
        }

        // Load the specular texture
        const specular_map_name = std.mem.sliceTo(&config.specular_map_name, 0);
        var specular_tex_ptr: ?*resource_types.Texture = null;

        if (specular_map_name.len > 0) {
            logger.info("Loading specular texture for material '{s}': '{s}'", .{ name_slice, specular_map_name });
            const specular_tex_id = texture.loadFromFile(specular_map_name);
            if (specular_tex_id != texture.INVALID_TEXTURE_ID) {
                specular_tex_ptr = texture.getTexture(specular_tex_id);
                logger.info("Specular texture loaded successfully with ID: {d}", .{specular_tex_id});
            } else {
                logger.warn("Failed to load specular texture: '{s}'", .{specular_map_name});
            }
        }

        // If specular texture loading failed, use default white texture
        if (specular_tex_ptr == null) {
            specular_tex_ptr = texture.getDefaultTexture();
        }

        // Populate the material
        entry.material.id = material_id;
        entry.material.generation = 0;
        entry.material.internal_id = 0;
        entry.material.diffuse_colour = config.diffuse_colour;
        entry.material.diffuse_map.texture = tex_ptr.?;
        entry.material.diffuse_map.use = .TEXTURE_USE_MAP_DIFFUSE;
        entry.material.specular_map.texture = specular_tex_ptr.?;
        entry.material.specular_map.use = .TEXTURE_USE_MAP_SPECULAR;
        entry.material.specular_color = config.specular_color;
        entry.material.shininess = config.shininess;

        // Allocate material descriptor set (two-tier descriptor architecture)
        if (renderer.getSystem()) |render_sys| {
            entry.material.descriptor_set = switch (render_sys.backend) {
                .vulkan => |*v| blk: {
                    if (v.allocateMaterialDescriptorSet(tex_ptr.?, specular_tex_ptr.?)) |ds| {
                        break :blk @ptrFromInt(@intFromPtr(ds));
                    }
                    break :blk null;
                },
                .metal => |*m| m.allocateMaterialDescriptorSet(tex_ptr.?, specular_tex_ptr.?),
                else => null,
            };
            if (entry.material.descriptor_set == null) {
                logger.warn("Failed to allocate descriptor set for material '{s}' - will use default", .{name_slice});
            }
        }

        // Copy name to material
        @memcpy(&entry.material.name, &config.name);

        entry.ref_count = 1;
        entry.is_valid = true;
        entry.auto_release = config.auto_release;
        entry.texture_id = tex_id;

        // Store name for cache lookup
        const name_copy = std.heap.page_allocator.dupe(u8, name_slice) catch {
            logger.err("Failed to allocate name for material cache", .{});
            return &entry.material; // Still return valid material, just won't be cached by name
        };

        entry.name = name_copy;
        self.name_lookup.put(name_copy, material_id) catch {
            logger.warn("Failed to add material to cache: {s}", .{name_slice});
            std.heap.page_allocator.free(name_copy);
            entry.name = null;
        };

        logger.info("Material created: {s} (id={})", .{ name_slice, material_id });
        return &entry.material;
    }

    /// Release a material by name. Destroys if ref_count reaches 0 and auto_release is true.
    pub fn release(self: *MaterialSystem, name: []const u8) void {
        const material_id = self.name_lookup.get(name) orelse return;

        if (material_id == INVALID_MATERIAL_ID) return;
        if (material_id == self.default_material_id) return; // Never release default

        const idx = material_id - 1;
        if (idx >= MAX_MATERIALS or !self.materials[idx].is_valid) return;

        if (self.materials[idx].ref_count > 0) {
            self.materials[idx].ref_count -= 1;
        }

        if (self.materials[idx].ref_count == 0 and self.materials[idx].auto_release) {
            // Release the texture
            if (self.materials[idx].texture_id != texture.INVALID_TEXTURE_ID) {
                texture.release(self.materials[idx].texture_id);
            }

            // Remove from name cache
            if (self.materials[idx].name) |mat_name| {
                _ = self.name_lookup.remove(mat_name);
                std.heap.page_allocator.free(mat_name);
            }

            self.materials[idx].is_valid = false;
            self.materials[idx].name = null;
            logger.debug("Material released and destroyed: {s} (id={})", .{ name, material_id });
        }
    }

    /// Get a material by ID. Returns null if invalid.
    pub fn getMaterial(self: *MaterialSystem, id: u32) ?*resource_types.Material {
        if (id == INVALID_MATERIAL_ID) return null;

        const idx = id - 1;
        if (idx >= MAX_MATERIALS) return null;
        if (!self.materials[idx].is_valid) return null;

        return &self.materials[idx].material;
    }

    /// Get the default material ID
    pub fn getDefaultMaterialId(self: *MaterialSystem) u32 {
        return self.default_material_id;
    }

    /// Get the default material
    pub fn getDefaultMaterial(self: *MaterialSystem) ?*resource_types.Material {
        return self.getMaterial(self.default_material_id);
    }

    /// Bind a material for rendering by ID. Pass INVALID_MATERIAL_ID for default.
    pub fn bind(self: *MaterialSystem, id: u32) void {
        const mat = if (id == INVALID_MATERIAL_ID)
            self.getDefaultMaterial()
        else
            self.getMaterial(id);

        if (renderer.getSystem()) |render_sys| {
            if (mat) |m| {
                render_sys.bindTexture(m.diffuse_map.texture);
                render_sys.bindSpecularTexture(m.specular_map.texture);
            } else {
                render_sys.bindTexture(null);
                render_sys.bindSpecularTexture(null);
            }
        }
    }

    /// Check if a material participates in a given render pass
    pub fn participatesInPass(self: *MaterialSystem, id: u32, pass_name: []const u8) bool {
        if (id == INVALID_MATERIAL_ID) return false;

        const idx = id - 1;
        if (idx >= MAX_MATERIALS) return false;
        if (!self.materials[idx].is_valid) return false;

        return self.materials[idx].participatesInPass(pass_name);
    }

    /// Get shader info for a material's specific render pass
    pub fn getPassShaderInfo(self: *MaterialSystem, id: u32, pass_name: []const u8) ?*const PassShaderInfo {
        if (id == INVALID_MATERIAL_ID) return null;

        const idx = id - 1;
        if (idx >= MAX_MATERIALS) return null;
        if (!self.materials[idx].is_valid) return null;

        return self.materials[idx].getPassShaderInfo(pass_name);
    }

    /// Get all passes this material participates in
    pub fn getMaterialPasses(self: *MaterialSystem, id: u32) []const [MAX_PASS_NAME_LENGTH]u8 {
        if (id == INVALID_MATERIAL_ID) return &[_][MAX_PASS_NAME_LENGTH]u8{};

        const idx = id - 1;
        if (idx >= MAX_MATERIALS) return &[_][MAX_PASS_NAME_LENGTH]u8{};
        if (!self.materials[idx].is_valid) return &[_][MAX_PASS_NAME_LENGTH]u8{};

        return self.materials[idx].pass_names[0..self.materials[idx].pass_count];
    }

    // ========== Private helpers ==========

    fn createDefaultMaterial(self: *MaterialSystem) bool {
        var config: MaterialConfig = .{
            .name = [_]u8{0} ** resource_types.MATERIAL_NAME_MAX_LENGTH,
            .auto_release = false,
            .diffuse_colour = .{ .elements = .{ 1.0, 1.0, 1.0, 1.0 } },
            .diffuse_map_name = [_]u8{0} ** resource_types.TEXTURE_NAME_MAX_LENGTH,
        };

        // Set name
        const default_name = "default";
        @memcpy(config.name[0..default_name.len], default_name);

        const mat = self.acquireFromConfig(config);
        if (mat == null) return false;

        self.default_material_id = mat.?.id;
        logger.info("Default material created (id={})", .{self.default_material_id});
        return true;
    }

    fn loadFromFile(self: *MaterialSystem, path: []const u8) u32 {
        // Open the file
        var file_handle: filesystem.FileHandle = .{};
        if (!filesystem.open(path, .{ .read = true }, &file_handle)) {
            logger.err("Failed to open material file: {s}", .{path});
            return INVALID_MATERIAL_ID;
        }
        defer filesystem.close(&file_handle);

        // Read all file bytes
        const file_data = filesystem.readAllBytes(&file_handle, std.heap.page_allocator) orelse {
            logger.err("Failed to read material file: {s}", .{path});
            return INVALID_MATERIAL_ID;
        };
        defer std.heap.page_allocator.free(file_data);

        // Parse the file
        var config: MaterialConfig = .{
            .name = [_]u8{0} ** resource_types.MATERIAL_NAME_MAX_LENGTH,
            .auto_release = true,
            .diffuse_colour = .{ .elements = .{ 1.0, 1.0, 1.0, 1.0 } },
            .diffuse_map_name = [_]u8{0} ** resource_types.TEXTURE_NAME_MAX_LENGTH,
        };

        var lines = std.mem.splitScalar(u8, file_data, '\n');
        while (lines.next()) |line| {
            // Skip empty lines and comments
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Split on '='
            var parts = std.mem.splitScalar(u8, trimmed, '=');
            const key = parts.next() orelse continue;
            const value = parts.next() orelse continue;

            const key_trimmed = std.mem.trim(u8, key, " \t");
            const value_trimmed = std.mem.trim(u8, value, " \t");

            if (std.mem.eql(u8, key_trimmed, "name")) {
                const copy_len = @min(value_trimmed.len, resource_types.MATERIAL_NAME_MAX_LENGTH - 1);
                @memcpy(config.name[0..copy_len], value_trimmed[0..copy_len]);
            } else if (std.mem.eql(u8, key_trimmed, "diffuse_colour")) {
                // Parse "r,g,b,a" format
                config.diffuse_colour = parseVec4(value_trimmed);
            } else if (std.mem.eql(u8, key_trimmed, "diffuse_map")) {
                const copy_len = @min(value_trimmed.len, resource_types.TEXTURE_NAME_MAX_LENGTH - 1);
                @memcpy(config.diffuse_map_name[0..copy_len], value_trimmed[0..copy_len]);
            } else if (std.mem.eql(u8, key_trimmed, "specular_map")) {
                const copy_len = @min(value_trimmed.len, resource_types.TEXTURE_NAME_MAX_LENGTH - 1);
                @memcpy(config.specular_map_name[0..copy_len], value_trimmed[0..copy_len]);
            } else if (std.mem.eql(u8, key_trimmed, "specular_color")) {
                // Parse "r,g,b" format
                config.specular_color = parseVec3(value_trimmed);
            } else if (std.mem.eql(u8, key_trimmed, "shininess")) {
                config.shininess = std.fmt.parseFloat(f32, value_trimmed) catch 32.0;
            } else if (std.mem.eql(u8, key_trimmed, "auto_release")) {
                config.auto_release = std.mem.eql(u8, value_trimmed, "true");
            }
        }

        // Create material from parsed config
        const mat = self.acquireFromConfig(config);
        if (mat == null) {
            return INVALID_MATERIAL_ID;
        }

        return mat.?.id;
    }

    fn parseVec4(value: []const u8) math_types.Vec4 {
        var result: math_types.Vec4 = .{ .elements = .{ 1.0, 1.0, 1.0, 1.0 } };
        var parts = std.mem.splitScalar(u8, value, ',');
        var i: usize = 0;
        while (parts.next()) |part| {
            if (i >= 4) break;
            const trimmed = std.mem.trim(u8, part, " \t");
            result.elements[i] = std.fmt.parseFloat(f32, trimmed) catch 1.0;
            i += 1;
        }
        return result;
    }

    fn parseVec3(value: []const u8) [3]f32 {
        var result: [3]f32 = .{ 1.0, 1.0, 1.0 };
        var parts = std.mem.splitScalar(u8, value, ',');
        var i: usize = 0;
        while (parts.next()) |part| {
            if (i >= 3) break;
            const trimmed = std.mem.trim(u8, part, " \t");
            result[i] = std.fmt.parseFloat(f32, trimmed) catch 1.0;
            i += 1;
        }
        return result;
    }

    fn allocateId(self: *MaterialSystem) ?u32 {
        // First try using next_id if it's still valid
        if (self.next_id <= MAX_MATERIALS) {
            const id = self.next_id;
            self.next_id += 1;
            return id;
        }

        // Otherwise, find a free slot
        for (self.materials, 0..) |entry, i| {
            if (!entry.is_valid) {
                return @intCast(i + 1);
            }
        }

        return null; // No free slots
    }

    // ========== Async Loading API ==========

    /// Async material loading arguments
    const AsyncAcquireArgs = struct {
        name_copy: []const u8,
        callback: ?*const fn (?*resource_types.Material) void,
    };

    /// Acquire material asynchronously using job system
    /// Returns job handle that can be waited on
    /// Callback is invoked on main thread when loading completes
    pub fn acquireAsync(
        self: *MaterialSystem,
        name: []const u8,
        callback: ?*const fn (?*resource_types.Material) void,
    ) !jobs.JobHandle {
        // Check cache first
        if (self.name_lookup.get(name)) |existing_id| {
            const idx = existing_id - 1;
            self.materials[idx].ref_count += 1;
            logger.debug("Material cache hit (async): {s} (id={}, ref_count={})", .{ name, existing_id, self.materials[idx].ref_count });

            // Immediately invoke callback with cached material
            if (callback) |cb| {
                cb(&self.materials[idx].material);
            }

            // Return invalid handle since job didn't run
            return jobs.INVALID_JOB_HANDLE;
        }

        // Duplicate name for the job (freed in job function)
        const name_copy = try std.heap.page_allocator.dupe(u8, name);
        errdefer std.heap.page_allocator.free(name_copy);

        const jobs_sys = context.get().jobs orelse return error.JobSystemNotInitialized;

        // Submit background job for file I/O and parsing
        const load_handle = try jobs_sys.submit(asyncAcquireJob, .{AsyncAcquireArgs{
            .name_copy = name_copy,
            .callback = callback,
        }});

        return load_handle;
    }

    /// Background job that loads material from file
    fn asyncAcquireJob(args: AsyncAcquireArgs) void {
        defer std.heap.page_allocator.free(args.name_copy);

        _ = getSystem() orelse {
            logger.err("Material system not available in async load job", .{});
            if (args.callback) |cb| cb(null);
            return;
        };

        // Build path to material file
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "../assets/materials/{s}.bmt", .{args.name_copy}) catch {
            logger.err("Material name too long (async): {s}", .{args.name_copy});
            if (args.callback) |cb| cb(null);
            return;
        };

        // 1. Load file from disk (I/O-bound)
        var file_handle: filesystem.FileHandle = .{};
        if (!filesystem.open(path, .{ .read = true }, &file_handle)) {
            logger.err("Failed to open material file (async): {s}", .{path});
            if (args.callback) |cb| cb(null);
            return;
        }
        defer filesystem.close(&file_handle);

        const file_data = filesystem.readAllBytes(&file_handle, std.heap.page_allocator) orelse {
            logger.err("Failed to read material file (async): {s}", .{path});
            if (args.callback) |cb| cb(null);
            return;
        };
        defer std.heap.page_allocator.free(file_data);

        // 2. Parse material config (CPU-bound)
        var config: MaterialConfig = .{
            .name = [_]u8{0} ** resource_types.MATERIAL_NAME_MAX_LENGTH,
            .auto_release = true,
            .diffuse_colour = .{ .elements = .{ 1.0, 1.0, 1.0, 1.0 } },
            .diffuse_map_name = [_]u8{0} ** resource_types.TEXTURE_NAME_MAX_LENGTH,
        };

        var lines = std.mem.splitScalar(u8, file_data, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var parts = std.mem.splitScalar(u8, trimmed, '=');
            const key = parts.next() orelse continue;
            const value = parts.next() orelse continue;

            const key_trimmed = std.mem.trim(u8, key, " \t");
            const value_trimmed = std.mem.trim(u8, value, " \t");

            if (std.mem.eql(u8, key_trimmed, "name")) {
                const copy_len = @min(value_trimmed.len, resource_types.MATERIAL_NAME_MAX_LENGTH - 1);
                @memcpy(config.name[0..copy_len], value_trimmed[0..copy_len]);
            } else if (std.mem.eql(u8, key_trimmed, "diffuse_colour")) {
                const color = parseVec3(value_trimmed);
                config.diffuse_colour = .{ .elements = .{ color[0], color[1], color[2], 1.0 } };
            } else if (std.mem.eql(u8, key_trimmed, "diffuse_map")) {
                const copy_len = @min(value_trimmed.len, resource_types.TEXTURE_NAME_MAX_LENGTH - 1);
                @memcpy(config.diffuse_map_name[0..copy_len], value_trimmed[0..copy_len]);
            } else if (std.mem.eql(u8, key_trimmed, "specular_map")) {
                const copy_len = @min(value_trimmed.len, resource_types.TEXTURE_NAME_MAX_LENGTH - 1);
                @memcpy(config.specular_map_name[0..copy_len], value_trimmed[0..copy_len]);
            } else if (std.mem.eql(u8, key_trimmed, "specular_color")) {
                config.specular_color = parseVec3(value_trimmed);
            } else if (std.mem.eql(u8, key_trimmed, "shininess")) {
                config.shininess = std.fmt.parseFloat(f32, value_trimmed) catch 32.0;
            }
        }

        // Copy config for main thread (it will be freed there)
        const config_copy = std.heap.page_allocator.create(MaterialConfig) catch {
            logger.err("Failed to allocate config for async material creation", .{});
            if (args.callback) |cb| cb(null);
            return;
        };
        config_copy.* = config;

        // 3. Submit material creation job to main thread (may need to load textures)
        const jobs_sys = context.get().jobs orelse {
            std.heap.page_allocator.destroy(config_copy);
            logger.err("Job system not available for material creation", .{});
            if (args.callback) |cb| cb(null);
            return;
        };

        const create_args = AsyncCreateArgs{
            .config = config_copy,
            .callback = args.callback,
        };

        _ = jobs_sys.submitMainThread(asyncCreateMaterialJob, .{create_args}) catch {
            std.heap.page_allocator.destroy(config_copy);
            logger.err("Failed to submit material creation job", .{});
            if (args.callback) |cb| cb(null);
        };
    }

    /// Arguments for material creation job
    const AsyncCreateArgs = struct {
        config: *MaterialConfig,
        callback: ?*const fn (?*resource_types.Material) void,
    };

    /// Main-thread job that creates material (may load textures)
    fn asyncCreateMaterialJob(args: AsyncCreateArgs) void {
        defer std.heap.page_allocator.destroy(args.config);

        const sys = getSystem() orelse {
            logger.err("Material system not available in creation job", .{});
            if (args.callback) |cb| cb(null);
            return;
        };

        // Create material from config (this may synchronously load textures)
        const mat = sys.acquireFromConfig(args.config.*);
        if (mat == null) {
            logger.err("Failed to create material from config (async)", .{});
            if (args.callback) |cb| cb(null);
            return;
        }

        const name_slice = std.mem.sliceTo(&args.config.name, 0);
        logger.info("Material loaded asynchronously: {s} (id={})", .{ name_slice, mat.?.id });

        // Invoke callback
        if (args.callback) |cb| {
            cb(mat);
        }
    }
};

/// Get the material system instance
pub fn getSystem() ?*MaterialSystem {
    return context.get().material;
}

// ========== Public API (Used by Resource Manager) ==========

/// Load material synchronously (used by Resource Manager)
pub fn acquire(name: []const u8) ?*resource_types.Material {
    const sys = getSystem() orelse return null;
    return sys.acquire(name);
}

/// Load material asynchronously (used by Resource Manager)
pub fn acquireAsync(
    name: []const u8,
    callback: ?*const fn (?*resource_types.Material) void,
) !jobs.JobHandle {
    const sys = getSystem() orelse return error.SystemNotInitialized;
    return sys.acquireAsync(name, callback);
}

// ========== Internal/Legacy API ==========

pub fn release(name: []const u8) void {
    if (getSystem()) |sys| {
        sys.release(name);
    }
}

pub fn getMaterial(id: u32) ?*resource_types.Material {
    const sys = getSystem() orelse return null;
    return sys.getMaterial(id);
}

pub fn getDefaultMaterial() ?*resource_types.Material {
    const sys = getSystem() orelse return null;
    return sys.getDefaultMaterial();
}

pub fn bind(id: u32) void {
    if (getSystem()) |sys| {
        sys.bind(id);
    }
}

pub fn participatesInPass(id: u32, pass_name: []const u8) bool {
    const sys = getSystem() orelse return false;
    return sys.participatesInPass(id, pass_name);
}

pub fn getPassShaderInfo(id: u32, pass_name: []const u8) ?*const PassShaderInfo {
    const sys = getSystem() orelse return null;
    return sys.getPassShaderInfo(id, pass_name);
}
