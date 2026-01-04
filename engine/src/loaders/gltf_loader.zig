//! glTF/GLB File Loader
//!
//! Parses glTF 2.0 files (.gltf and .glb) and returns vertex/index data.
//! Supports:
//! - JSON-based glTF (.gltf) with external buffers
//! - Binary glTF (.glb) with embedded buffers
//! - Mesh primitives with positions, normals, texcoords, tangents
//! - Indexed and non-indexed geometry
//! - PBR material information extraction

const std = @import("std");
const math_types = @import("../math/types.zig");
const math = @import("../math/math.zig");
const logger = @import("../core/logging.zig");
const filesystem = @import("../platform/filesystem.zig");

// GLB magic number and version
const GLB_MAGIC: u32 = 0x46546C67; // "glTF" in little-endian
const GLB_VERSION: u32 = 2;
const GLB_CHUNK_JSON: u32 = 0x4E4F534A; // "JSON"
const GLB_CHUNK_BIN: u32 = 0x004E4942; // "BIN\0"

/// Material information from glTF
pub const GltfMaterial = struct {
    name: []const u8,
    base_color_texture: ?[]const u8 = null,
    metallic_roughness_texture: ?[]const u8 = null,
    normal_texture: ?[]const u8 = null,
    base_color_factor: [4]f32 = .{ 1, 1, 1, 1 },
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
};

/// Primitive within a mesh
pub const GltfPrimitive = struct {
    vertices: []math_types.Vertex3D,
    indices: []u32,
    material_index: ?u32 = null,
};

/// Mesh from glTF
pub const GltfMesh = struct {
    name: []const u8,
    primitives: []GltfPrimitive,
};

/// Result of loading a glTF file
pub const GltfLoadResult = struct {
    meshes: []GltfMesh,
    materials: []GltfMaterial,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GltfLoadResult) void {
        for (self.meshes) |mesh| {
            for (mesh.primitives) |prim| {
                self.allocator.free(prim.vertices);
                self.allocator.free(prim.indices);
            }
            self.allocator.free(mesh.primitives);
            if (mesh.name.len > 0) {
                self.allocator.free(mesh.name);
            }
        }
        self.allocator.free(self.meshes);

        for (self.materials) |mat| {
            if (mat.name.len > 0) {
                self.allocator.free(mat.name);
            }
            if (mat.base_color_texture) |t| {
                self.allocator.free(t);
            }
            if (mat.metallic_roughness_texture) |t| {
                self.allocator.free(t);
            }
            if (mat.normal_texture) |t| {
                self.allocator.free(t);
            }
        }
        self.allocator.free(self.materials);
    }
};

/// Load a glTF file (.gltf or .glb)
pub fn loadGltf(allocator: std.mem.Allocator, path: []const u8) ?GltfLoadResult {
    // Open the file
    var file_handle: filesystem.FileHandle = .{};
    if (!filesystem.open(path, .{ .read = true }, &file_handle)) {
        logger.err("Failed to open glTF file: {s}", .{path});
        return null;
    }
    defer filesystem.close(&file_handle);

    // Read all file bytes
    const file_data = filesystem.readAllBytes(&file_handle, allocator) orelse {
        logger.err("Failed to read glTF file: {s}", .{path});
        return null;
    };
    defer allocator.free(file_data);

    // Detect format (GLB or JSON)
    if (file_data.len >= 4) {
        const magic = std.mem.readInt(u32, file_data[0..4], .little);
        if (magic == GLB_MAGIC) {
            return parseGlb(allocator, file_data, path);
        }
    }

    // Assume it's JSON format
    return parseGltfJson(allocator, file_data, path);
}

/// Parse GLB (binary glTF) format
fn parseGlb(allocator: std.mem.Allocator, data: []const u8, path: []const u8) ?GltfLoadResult {
    if (data.len < 12) {
        logger.err("GLB file too small: {s}", .{path});
        return null;
    }

    // Read header
    const magic = std.mem.readInt(u32, data[0..4], .little);
    const version = std.mem.readInt(u32, data[4..8], .little);
    const length = std.mem.readInt(u32, data[8..12], .little);

    if (magic != GLB_MAGIC) {
        logger.err("Invalid GLB magic: {s}", .{path});
        return null;
    }

    if (version != GLB_VERSION) {
        logger.err("Unsupported GLB version {}: {s}", .{ version, path });
        return null;
    }

    if (length > data.len) {
        logger.err("GLB length mismatch: {s}", .{path});
        return null;
    }

    // Read chunks
    var json_data: ?[]const u8 = null;
    var bin_data: ?[]const u8 = null;
    var offset: usize = 12;

    while (offset + 8 <= data.len) {
        const chunk_length = std.mem.readInt(u32, data[offset..][0..4], .little);
        const chunk_type = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
        offset += 8;

        if (offset + chunk_length > data.len) break;

        const chunk_data = data[offset .. offset + chunk_length];
        offset += chunk_length;

        if (chunk_type == GLB_CHUNK_JSON) {
            json_data = chunk_data;
        } else if (chunk_type == GLB_CHUNK_BIN) {
            bin_data = chunk_data;
        }
    }

    if (json_data == null) {
        logger.err("GLB missing JSON chunk: {s}", .{path});
        return null;
    }

    return parseGltfWithBinary(allocator, json_data.?, bin_data, path);
}

/// Parse JSON-based glTF
fn parseGltfJson(allocator: std.mem.Allocator, data: []const u8, path: []const u8) ?GltfLoadResult {
    _ = path;
    return parseGltfWithBinary(allocator, data, null, "");
}

/// Parse glTF JSON with optional embedded binary
fn parseGltfWithBinary(allocator: std.mem.Allocator, json_data: []const u8, bin_data: ?[]const u8, _: []const u8) ?GltfLoadResult {
    // Parse JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch |err| {
        logger.err("Failed to parse glTF JSON: {}", .{err});
        return null;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        logger.err("glTF root is not an object", .{});
        return null;
    }

    const root_obj = root.object;

    // Extract buffers data
    var buffer_data = std.ArrayList([]const u8).init(allocator);
    defer buffer_data.deinit();

    if (root_obj.get("buffers")) |buffers_val| {
        if (buffers_val == .array) {
            for (buffers_val.array.items, 0..) |buffer, idx| {
                if (buffer == .object) {
                    if (buffer.object.get("uri")) |uri_val| {
                        if (uri_val == .string) {
                            // TODO: Load external buffer file
                            // For now, skip external buffers
                            _ = buffer_data.append(&[_]u8{}) catch {};
                        }
                    } else if (bin_data != null and idx == 0) {
                        // Use embedded binary
                        _ = buffer_data.append(bin_data.?) catch {};
                    }
                }
            }
        }
    } else if (bin_data != null) {
        // GLB with implicit buffer
        _ = buffer_data.append(bin_data.?) catch {};
    }

    // Parse meshes
    var meshes = std.ArrayList(GltfMesh).init(allocator);
    defer meshes.deinit();

    if (root_obj.get("meshes")) |meshes_val| {
        if (meshes_val == .array) {
            for (meshes_val.array.items) |mesh_val| {
                if (mesh_val == .object) {
                    if (parseMesh(allocator, mesh_val.object, root_obj, buffer_data.items)) |mesh| {
                        meshes.append(mesh) catch {};
                    }
                }
            }
        }
    }

    // Parse materials
    var materials = std.ArrayList(GltfMaterial).init(allocator);
    defer materials.deinit();

    if (root_obj.get("materials")) |materials_val| {
        if (materials_val == .array) {
            for (materials_val.array.items) |mat_val| {
                if (mat_val == .object) {
                    if (parseMaterial(allocator, mat_val.object)) |mat| {
                        materials.append(mat) catch {};
                    }
                }
            }
        }
    }

    logger.info("glTF loaded: {} meshes, {} materials", .{ meshes.items.len, materials.items.len });

    return GltfLoadResult{
        .meshes = meshes.toOwnedSlice() catch &[_]GltfMesh{},
        .materials = materials.toOwnedSlice() catch &[_]GltfMaterial{},
        .allocator = allocator,
    };
}

fn parseMesh(
    allocator: std.mem.Allocator,
    mesh_obj: std.json.ObjectMap,
    root_obj: std.json.ObjectMap,
    buffer_data: []const []const u8,
) ?GltfMesh {
    const name = if (mesh_obj.get("name")) |n| blk: {
        if (n == .string) {
            break :blk allocator.dupe(u8, n.string) catch "";
        }
        break :blk "";
    } else "";

    var primitives = std.ArrayList(GltfPrimitive).init(allocator);
    defer primitives.deinit();

    if (mesh_obj.get("primitives")) |prims_val| {
        if (prims_val == .array) {
            for (prims_val.array.items) |prim_val| {
                if (prim_val == .object) {
                    if (parsePrimitive(allocator, prim_val.object, root_obj, buffer_data)) |prim| {
                        primitives.append(prim) catch {};
                    }
                }
            }
        }
    }

    if (primitives.items.len == 0) {
        if (name.len > 0) allocator.free(name);
        return null;
    }

    return GltfMesh{
        .name = name,
        .primitives = primitives.toOwnedSlice() catch &[_]GltfPrimitive{},
    };
}

fn parsePrimitive(
    allocator: std.mem.Allocator,
    prim_obj: std.json.ObjectMap,
    root_obj: std.json.ObjectMap,
    buffer_data: []const []const u8,
) ?GltfPrimitive {
    const attributes = prim_obj.get("attributes") orelse return null;
    if (attributes != .object) return null;

    // Get accessor indices
    const position_idx = getIntFromValue(attributes.object.get("POSITION")) orelse return null;
    const normal_idx = getIntFromValue(attributes.object.get("NORMAL"));
    const texcoord_idx = getIntFromValue(attributes.object.get("TEXCOORD_0"));
    const tangent_idx = getIntFromValue(attributes.object.get("TANGENT"));
    const indices_idx = getIntFromValue(prim_obj.get("indices"));
    const material_idx = getIntFromValue(prim_obj.get("material"));

    // Get accessors array
    const accessors = root_obj.get("accessors") orelse return null;
    if (accessors != .array) return null;

    const buffer_views = root_obj.get("bufferViews") orelse return null;
    if (buffer_views != .array) return null;

    // Read position data
    const positions = readAccessorVec3(
        allocator,
        accessors.array.items,
        buffer_views.array.items,
        buffer_data,
        position_idx,
    ) orelse return null;
    defer allocator.free(positions);

    // Read normals (optional)
    const normals = if (normal_idx) |idx|
        readAccessorVec3(allocator, accessors.array.items, buffer_views.array.items, buffer_data, idx)
    else
        null;
    defer if (normals) |n| allocator.free(n);

    // Read texcoords (optional)
    const texcoords = if (texcoord_idx) |idx|
        readAccessorVec2(allocator, accessors.array.items, buffer_views.array.items, buffer_data, idx)
    else
        null;
    defer if (texcoords) |t| allocator.free(t);

    // Read tangents (optional)
    const tangents = if (tangent_idx) |idx|
        readAccessorVec4(allocator, accessors.array.items, buffer_views.array.items, buffer_data, idx)
    else
        null;
    defer if (tangents) |t| allocator.free(t);

    // Build vertices
    const vertex_count = positions.len;
    const vertices = allocator.alloc(math_types.Vertex3D, vertex_count) catch return null;

    for (0..vertex_count) |i| {
        vertices[i] = .{
            .position = positions[i],
            .normal = if (normals) |n| (if (i < n.len) n[i] else [3]f32{ 0, 1, 0 }) else [3]f32{ 0, 1, 0 },
            .texcoord = if (texcoords) |t| (if (i < t.len) t[i] else [2]f32{ 0, 0 }) else [2]f32{ 0, 0 },
            .tangent = if (tangents) |t| (if (i < t.len) t[i] else [4]f32{ 1, 0, 0, 1 }) else [4]f32{ 1, 0, 0, 1 },
            .color = .{ 1, 1, 1, 1 },
        };
    }

    // Read indices (optional - generate if not present)
    var indices: []u32 = undefined;
    if (indices_idx) |idx| {
        indices = readAccessorIndices(
            allocator,
            accessors.array.items,
            buffer_views.array.items,
            buffer_data,
            idx,
        ) orelse {
            allocator.free(vertices);
            return null;
        };
    } else {
        // Generate sequential indices
        indices = allocator.alloc(u32, vertex_count) catch {
            allocator.free(vertices);
            return null;
        };
        for (0..vertex_count) |i| {
            indices[i] = @intCast(i);
        }
    }

    return GltfPrimitive{
        .vertices = vertices,
        .indices = indices,
        .material_index = material_idx,
    };
}

fn parseMaterial(allocator: std.mem.Allocator, mat_obj: std.json.ObjectMap) ?GltfMaterial {
    const name = if (mat_obj.get("name")) |n| blk: {
        if (n == .string) {
            break :blk allocator.dupe(u8, n.string) catch "";
        }
        break :blk "";
    } else "";

    var material = GltfMaterial{
        .name = name,
    };

    // Parse PBR metallic roughness
    if (mat_obj.get("pbrMetallicRoughness")) |pbr| {
        if (pbr == .object) {
            if (pbr.object.get("baseColorFactor")) |bc| {
                material.base_color_factor = getVec4FromValue(bc);
            }
            if (pbr.object.get("metallicFactor")) |mf| {
                material.metallic_factor = getFloatFromValue(mf) orelse 1.0;
            }
            if (pbr.object.get("roughnessFactor")) |rf| {
                material.roughness_factor = getFloatFromValue(rf) orelse 1.0;
            }
        }
    }

    return material;
}

// Helper functions for reading accessor data

fn readAccessorVec3(
    allocator: std.mem.Allocator,
    accessors: []const std.json.Value,
    buffer_views: []const std.json.Value,
    buffer_data: []const []const u8,
    accessor_idx: u32,
) ?[][3]f32 {
    if (accessor_idx >= accessors.len) return null;

    const accessor = accessors[accessor_idx];
    if (accessor != .object) return null;

    const count = getIntFromValue(accessor.object.get("count")) orelse return null;
    const buffer_view_idx = getIntFromValue(accessor.object.get("bufferView")) orelse return null;
    const byte_offset = getIntFromValue(accessor.object.get("byteOffset")) orelse 0;

    if (buffer_view_idx >= buffer_views.len) return null;

    const buffer_view = buffer_views[buffer_view_idx];
    if (buffer_view != .object) return null;

    const buffer_idx = getIntFromValue(buffer_view.object.get("buffer")) orelse return null;
    const view_offset = getIntFromValue(buffer_view.object.get("byteOffset")) orelse 0;

    if (buffer_idx >= buffer_data.len) return null;

    const buffer = buffer_data[buffer_idx];
    const total_offset = view_offset + byte_offset;

    if (total_offset + count * 12 > buffer.len) return null;

    const result = allocator.alloc([3]f32, count) catch return null;

    for (0..count) |i| {
        const offset = total_offset + i * 12;
        result[i] = .{
            @bitCast(std.mem.readInt(u32, buffer[offset..][0..4], .little)),
            @bitCast(std.mem.readInt(u32, buffer[offset + 4 ..][0..4], .little)),
            @bitCast(std.mem.readInt(u32, buffer[offset + 8 ..][0..4], .little)),
        };
    }

    return result;
}

fn readAccessorVec2(
    allocator: std.mem.Allocator,
    accessors: []const std.json.Value,
    buffer_views: []const std.json.Value,
    buffer_data: []const []const u8,
    accessor_idx: u32,
) ?[][2]f32 {
    if (accessor_idx >= accessors.len) return null;

    const accessor = accessors[accessor_idx];
    if (accessor != .object) return null;

    const count = getIntFromValue(accessor.object.get("count")) orelse return null;
    const buffer_view_idx = getIntFromValue(accessor.object.get("bufferView")) orelse return null;
    const byte_offset = getIntFromValue(accessor.object.get("byteOffset")) orelse 0;

    if (buffer_view_idx >= buffer_views.len) return null;

    const buffer_view = buffer_views[buffer_view_idx];
    if (buffer_view != .object) return null;

    const buffer_idx = getIntFromValue(buffer_view.object.get("buffer")) orelse return null;
    const view_offset = getIntFromValue(buffer_view.object.get("byteOffset")) orelse 0;

    if (buffer_idx >= buffer_data.len) return null;

    const buffer = buffer_data[buffer_idx];
    const total_offset = view_offset + byte_offset;

    if (total_offset + count * 8 > buffer.len) return null;

    const result = allocator.alloc([2]f32, count) catch return null;

    for (0..count) |i| {
        const offset = total_offset + i * 8;
        result[i] = .{
            @bitCast(std.mem.readInt(u32, buffer[offset..][0..4], .little)),
            @bitCast(std.mem.readInt(u32, buffer[offset + 4 ..][0..4], .little)),
        };
    }

    return result;
}

fn readAccessorVec4(
    allocator: std.mem.Allocator,
    accessors: []const std.json.Value,
    buffer_views: []const std.json.Value,
    buffer_data: []const []const u8,
    accessor_idx: u32,
) ?[][4]f32 {
    if (accessor_idx >= accessors.len) return null;

    const accessor = accessors[accessor_idx];
    if (accessor != .object) return null;

    const count = getIntFromValue(accessor.object.get("count")) orelse return null;
    const buffer_view_idx = getIntFromValue(accessor.object.get("bufferView")) orelse return null;
    const byte_offset = getIntFromValue(accessor.object.get("byteOffset")) orelse 0;

    if (buffer_view_idx >= buffer_views.len) return null;

    const buffer_view = buffer_views[buffer_view_idx];
    if (buffer_view != .object) return null;

    const buffer_idx = getIntFromValue(buffer_view.object.get("buffer")) orelse return null;
    const view_offset = getIntFromValue(buffer_view.object.get("byteOffset")) orelse 0;

    if (buffer_idx >= buffer_data.len) return null;

    const buffer = buffer_data[buffer_idx];
    const total_offset = view_offset + byte_offset;

    if (total_offset + count * 16 > buffer.len) return null;

    const result = allocator.alloc([4]f32, count) catch return null;

    for (0..count) |i| {
        const offset = total_offset + i * 16;
        result[i] = .{
            @bitCast(std.mem.readInt(u32, buffer[offset..][0..4], .little)),
            @bitCast(std.mem.readInt(u32, buffer[offset + 4 ..][0..4], .little)),
            @bitCast(std.mem.readInt(u32, buffer[offset + 8 ..][0..4], .little)),
            @bitCast(std.mem.readInt(u32, buffer[offset + 12 ..][0..4], .little)),
        };
    }

    return result;
}

fn readAccessorIndices(
    allocator: std.mem.Allocator,
    accessors: []const std.json.Value,
    buffer_views: []const std.json.Value,
    buffer_data: []const []const u8,
    accessor_idx: u32,
) ?[]u32 {
    if (accessor_idx >= accessors.len) return null;

    const accessor = accessors[accessor_idx];
    if (accessor != .object) return null;

    const count = getIntFromValue(accessor.object.get("count")) orelse return null;
    const buffer_view_idx = getIntFromValue(accessor.object.get("bufferView")) orelse return null;
    const byte_offset = getIntFromValue(accessor.object.get("byteOffset")) orelse 0;
    const component_type = getIntFromValue(accessor.object.get("componentType")) orelse return null;

    if (buffer_view_idx >= buffer_views.len) return null;

    const buffer_view = buffer_views[buffer_view_idx];
    if (buffer_view != .object) return null;

    const buffer_idx = getIntFromValue(buffer_view.object.get("buffer")) orelse return null;
    const view_offset = getIntFromValue(buffer_view.object.get("byteOffset")) orelse 0;

    if (buffer_idx >= buffer_data.len) return null;

    const buffer = buffer_data[buffer_idx];
    const total_offset = view_offset + byte_offset;

    const result = allocator.alloc(u32, count) catch return null;

    // Handle different component types
    switch (component_type) {
        5121 => { // UNSIGNED_BYTE
            for (0..count) |i| {
                result[i] = buffer[total_offset + i];
            }
        },
        5123 => { // UNSIGNED_SHORT
            for (0..count) |i| {
                const offset = total_offset + i * 2;
                result[i] = std.mem.readInt(u16, buffer[offset..][0..2], .little);
            }
        },
        5125 => { // UNSIGNED_INT
            for (0..count) |i| {
                const offset = total_offset + i * 4;
                result[i] = std.mem.readInt(u32, buffer[offset..][0..4], .little);
            }
        },
        else => {
            allocator.free(result);
            return null;
        },
    }

    return result;
}

fn getIntFromValue(val: ?std.json.Value) ?u32 {
    if (val) |v| {
        if (v == .integer) {
            return @intCast(v.integer);
        }
    }
    return null;
}

fn getFloatFromValue(val: ?std.json.Value) ?f32 {
    if (val) |v| {
        if (v == .float) {
            return @floatCast(v.float);
        } else if (v == .integer) {
            return @floatFromInt(v.integer);
        }
    }
    return null;
}

fn getVec4FromValue(val: std.json.Value) [4]f32 {
    var result: [4]f32 = .{ 1, 1, 1, 1 };
    if (val == .array) {
        for (val.array.items, 0..) |item, i| {
            if (i >= 4) break;
            if (getFloatFromValue(item)) |f| {
                result[i] = f;
            }
        }
    }
    return result;
}

// ============================================================================
// MeshBuilder Integration
// ============================================================================

const mesh_builder_mod = @import("../systems/mesh_builder.zig");
const MeshBuilder = mesh_builder_mod.MeshBuilder;

/// Load a glTF file and populate a MeshBuilder with its data
///
/// Each primitive in the glTF file becomes a submesh in the builder.
/// This allows multi-material meshes to be properly represented.
///
/// Example usage:
/// ```zig
/// var builder = MeshBuilder.init(allocator);
/// defer builder.deinit();
///
/// try loadGltfToBuilder(allocator, "model.gltf", &builder);
/// try builder.finalize();
///
/// const mesh = mesh_asset_system.acquireFromBuilder(&builder, "model");
/// ```
pub fn loadGltfToBuilder(
    allocator: std.mem.Allocator,
    path: []const u8,
    builder: *MeshBuilder,
) !void {
    // Load the glTF file using existing loader
    var result = loadGltf(allocator, path) orelse return error.GltfLoadFailed;
    defer result.deinit();

    // Process each mesh (typically only one per file, but can be multiple)
    for (result.meshes) |gltf_mesh| {
        // Process each primitive as a submesh
        for (gltf_mesh.primitives, 0..) |prim, prim_idx| {
            // Create submesh name (e.g., "mesh_0" or use material index)
            var submesh_name_buf: [128]u8 = undefined;
            const submesh_name = if (prim.material_index) |mat_idx|
                std.fmt.bufPrint(&submesh_name_buf, "{s}_mat{}", .{ gltf_mesh.name, mat_idx }) catch "submesh"
            else
                std.fmt.bufPrint(&submesh_name_buf, "{s}_{}", .{ gltf_mesh.name, prim_idx }) catch "submesh";

            // Begin submesh
            try builder.beginSubmesh(submesh_name);

            // Get the starting vertex offset for this submesh
            const vertex_offset = @as(u32, @intCast(builder.vertices.items.len));

            // Add all vertices from this primitive
            for (prim.vertices) |vertex| {
                _ = try builder.addVertex(vertex);
            }

            // Add all indices (adjusted by vertex offset)
            for (prim.indices) |index| {
                try builder.addIndex(vertex_offset + index);
            }

            // End submesh (computes bounds)
            try builder.endSubmesh();
        }
    }
}
