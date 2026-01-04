//! Editor Scene System
//! Provides lightweight object tracking with transforms for the editor.
//! This is a simple scene representation, not a full ECS.

const std = @import("std");
const math = @import("../math/math.zig");
const mesh_asset_system = @import("../systems/mesh_asset.zig");
const geometry_system = @import("../systems/geometry.zig");
const handle = @import("../resources/handle.zig");

/// Invalid object ID constant
pub const INVALID_OBJECT_ID: EditorObjectId = 0;

/// Maximum length for object names
pub const OBJECT_NAME_MAX_LENGTH: usize = 64;

/// Object ID type
pub const EditorObjectId = u32;

/// Transform component - position, rotation (Euler), and scale
pub const Transform = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    rotation: [3]f32 = .{ 0, 0, 0 }, // Euler angles in degrees
    scale: [3]f32 = .{ 1, 1, 1 },

    /// Convert transform to a model matrix (TRS: Translation * Rotation * Scale)
    pub fn toModelMatrix(self: Transform) math.Mat4 {
        // Convert rotation from degrees to radians
        const rx = self.rotation[0] * math.K_DEG2RAD_MULTIPLIER;
        const ry = self.rotation[1] * math.K_DEG2RAD_MULTIPLIER;
        const rz = self.rotation[2] * math.K_DEG2RAD_MULTIPLIER;

        // Create individual matrices
        const translation = math.mat4Translation(self.position[0], self.position[1], self.position[2]);
        const rotation_x = math.mat4RotationX(rx);
        const rotation_y = math.mat4RotationY(ry);
        const rotation_z = math.mat4RotationZ(rz);

        // Create scale matrix manually (no mat4Scale in math lib)
        var scale_mat = math.mat4Identity();
        scale_mat.data[0] = self.scale[0];
        scale_mat.data[5] = self.scale[1];
        scale_mat.data[10] = self.scale[2];

        // Combine: T * Rz * Ry * Rx * S
        // Combine: S * R * T (Row-Major: v * S * R * T)
        const rotation_yx = math.mat4Mul(rotation_y, rotation_x);
        const rotation_zyx = math.mat4Mul(rotation_z, rotation_yx);

        // Scale then Rotation
        const scale_rotation = math.mat4Mul(scale_mat, rotation_zyx);

        // Then Translation
        return math.mat4Mul(scale_rotation, translation);
    }
};

/// Editor object - represents an object in the scene
pub const EditorObject = struct {
    id: EditorObjectId = INVALID_OBJECT_ID,
    name: [OBJECT_NAME_MAX_LENGTH]u8 = [_]u8{0} ** OBJECT_NAME_MAX_LENGTH,
    geometry: handle.GeometryHandle = handle.GeometryHandle.invalid, // DEPRECATED: Use mesh_asset
    mesh_asset: handle.MeshAssetHandle = handle.MeshAssetHandle.invalid,
    material: handle.MaterialHandle = handle.MaterialHandle.invalid,
    transform: Transform = .{},
    is_visible: bool = true,

    // Cached world-space bounding box (updated when transform changes)
    world_bounds_min: [3]f32 = .{ 0, 0, 0 },
    world_bounds_max: [3]f32 = .{ 0, 0, 0 },

    /// Get the object name as a slice
    pub fn getName(self: *const EditorObject) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    /// Get mesh asset ID for backwards compatibility with systems that use raw IDs
    pub fn getMeshAssetId(self: *const EditorObject) u32 {
        return self.mesh_asset.id;
    }

    /// Get geometry ID for backwards compatibility
    pub fn getGeometryId(self: *const EditorObject) u32 {
        return self.geometry.id;
    }

    /// Get material ID for backwards compatibility with systems that use raw IDs
    pub fn getMaterialId(self: *const EditorObject) u32 {
        return self.material.id;
    }
};

/// Editor scene - container for all editor objects
pub const EditorScene = struct {
    objects: std.ArrayList(EditorObject),
    next_id: EditorObjectId = 1,
    allocator: std.mem.Allocator,

    /// Initialize a new editor scene
    pub fn init(allocator: std.mem.Allocator) EditorScene {
        return .{
            .objects = .empty,
            .allocator = allocator,
        };
    }

    /// Deinitialize the editor scene
    pub fn deinit(self: *EditorScene) void {
        self.objects.deinit(self.allocator);
    }

    /// Add a new object to the scene using resource handles
    pub fn addObject(self: *EditorScene, name: []const u8, mesh_asset: handle.MeshAssetHandle, material: handle.MaterialHandle) EditorObjectId {
        const id = self.next_id;
        self.next_id += 1;

        var obj = EditorObject{
            .id = id,
            .mesh_asset = mesh_asset,
            .geometry = .{ .id = 0, .generation = 0 }, // Not using geometry anymore
            .material = material,
        };

        // Copy name
        const copy_len = @min(name.len, OBJECT_NAME_MAX_LENGTH - 1);
        @memcpy(obj.name[0..copy_len], name[0..copy_len]);
        obj.name[copy_len] = 0;

        // Update bounds from geometry
        self.updateBoundsFromGeometry(&obj);

        self.objects.append(self.allocator, obj) catch {
            return INVALID_OBJECT_ID;
        };

        return id;
    }

    /// Add a new object to the scene using raw IDs (backwards compatibility)
    /// Takes geometry_id for backward compatibility - stores in both geometry and mesh_asset fields
    pub fn addObjectById(self: *EditorScene, name: []const u8, geometry_id: u32, material_id: u32) EditorObjectId {
        const id = self.next_id;
        self.next_id += 1;

        var obj = EditorObject{
            .id = id,
            .geometry = .{ .id = geometry_id, .generation = 0 },
            .mesh_asset = .{ .id = 0, .generation = 0 }, // Not used in legacy mode
            .material = .{ .id = material_id, .generation = 0 },
        };

        // Copy name
        const copy_len = @min(name.len, OBJECT_NAME_MAX_LENGTH - 1);
        @memcpy(obj.name[0..copy_len], name[0..copy_len]);
        obj.name[copy_len] = 0;

        // Update bounds from geometry
        self.updateBoundsFromGeometry(&obj);

        self.objects.append(self.allocator, obj) catch {
            return INVALID_OBJECT_ID;
        };

        return id;
    }

    /// Remove an object from the scene
    pub fn removeObject(self: *EditorScene, id: EditorObjectId) bool {
        for (self.objects.items, 0..) |obj, i| {
            if (obj.id == id) {
                _ = self.objects.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Get an object by ID (mutable)
    pub fn getObject(self: *EditorScene, id: EditorObjectId) ?*EditorObject {
        for (self.objects.items) |*obj| {
            if (obj.id == id) {
                return obj;
            }
        }
        return null;
    }

    /// Get an object by ID (const)
    pub fn getObjectConst(self: *const EditorScene, id: EditorObjectId) ?*const EditorObject {
        for (self.objects.items) |*obj| {
            if (obj.id == id) {
                return obj;
            }
        }
        return null;
    }

    /// Get all objects
    pub fn getAllObjects(self: *EditorScene) []EditorObject {
        return self.objects.items;
    }

    /// Get object count
    pub fn getObjectCount(self: *const EditorScene) usize {
        return self.objects.items.len;
    }

    /// Update world bounds from geometry/mesh asset and transform
    pub fn updateBoundsFromGeometry(self: *EditorScene, obj: *EditorObject) void {
        _ = self;

        // Get bounding box (try both legacy geometry and new mesh_asset)
        var local_min: [3]f32 = .{ -0.5, -0.5, -0.5 };
        var local_max: [3]f32 = .{ 0.5, 0.5, 0.5 };

        // Try new mesh_asset system first
        if (obj.mesh_asset.isValid()) {
            const mesh_sys = mesh_asset_system.getSystem() orelse return;
            if (mesh_sys.getMesh(obj.mesh_asset.id)) |mesh| {
                local_min = mesh.bounding_min;
                local_max = mesh.bounding_max;
            }
        }
        // Fall back to legacy geometry system
        else if (obj.geometry.isValid()) {
            if (geometry_system.getGeometry(obj.geometry.id)) |geo| {
                local_min = geo.bounding_min;
                local_max = geo.bounding_max;
            }
        }

        // Transform bounds to world space (simple AABB transform)
        // For accurate bounds we'd transform all 8 corners and find new AABB
        const t = &obj.transform;

        // Scale the bounds
        const scaled_min: [3]f32 = .{
            local_min[0] * t.scale[0],
            local_min[1] * t.scale[1],
            local_min[2] * t.scale[2],
        };
        const scaled_max: [3]f32 = .{
            local_max[0] * t.scale[0],
            local_max[1] * t.scale[1],
            local_max[2] * t.scale[2],
        };

        // Translate to world position (ignoring rotation for simplicity)
        obj.world_bounds_min = .{
            scaled_min[0] + t.position[0],
            scaled_min[1] + t.position[1],
            scaled_min[2] + t.position[2],
        };
        obj.world_bounds_max = .{
            scaled_max[0] + t.position[0],
            scaled_max[1] + t.position[1],
            scaled_max[2] + t.position[2],
        };
    }

    /// Update bounds for an object (call after transform changes)
    pub fn updateBounds(self: *EditorScene, obj: *EditorObject) void {
        self.updateBoundsFromGeometry(obj);
    }

    /// Clear all objects from the scene
    pub fn clear(self: *EditorScene) void {
        self.objects.clearRetainingCapacity();
        self.next_id = 1;
    }
};
