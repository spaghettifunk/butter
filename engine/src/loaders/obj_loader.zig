//! OBJ File Loader
//!
//! Parses Wavefront OBJ files and returns vertex/index data.
//! Supports:
//! - Vertex positions (v)
//! - Texture coordinates (vt)
//! - Vertex normals (vn)
//! - Faces (f) with various formats: v, v/vt, v/vt/vn, v//vn
//! - Material references (usemtl)
//! - Object groups (o, g)

const std = @import("std");
const math_types = @import("../math/types.zig");
const math = @import("../math/math.zig");
const logger = @import("../core/logging.zig");
const filesystem = @import("../platform/filesystem.zig");

/// Sub-mesh information for multi-material support
pub const SubMesh = struct {
    index_start: u32,
    index_count: u32,
    material_name: []const u8,
};

/// Result of loading an OBJ file
pub const ObjLoadResult = struct {
    vertices: []math_types.Vertex3DExtended,
    indices: []u32,
    sub_meshes: []SubMesh,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ObjLoadResult) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
        for (self.sub_meshes) |sub_mesh| {
            if (sub_mesh.material_name.len > 0) {
                self.allocator.free(sub_mesh.material_name);
            }
        }
        self.allocator.free(self.sub_meshes);
    }
};

/// Internal face vertex structure
const FaceVertex = struct {
    position_idx: u32,
    texcoord_idx: u32,
    normal_idx: u32,
};

/// Load an OBJ file and return parsed data
/// Caller is responsible for calling deinit() on the result
pub fn loadObj(allocator: std.mem.Allocator, path: []const u8) ?ObjLoadResult {
    // Open the file
    var file_handle: filesystem.FileHandle = .{};
    if (!filesystem.open(path, .{ .read = true }, &file_handle)) {
        logger.err("Failed to open OBJ file: {s}", .{path});
        return null;
    }
    defer filesystem.close(&file_handle);

    // Read all file bytes
    const file_data = filesystem.readAllBytes(&file_handle, allocator) orelse {
        logger.err("Failed to read OBJ file: {s}", .{path});
        return null;
    };
    defer allocator.free(file_data);

    return parseObj(allocator, file_data);
}

/// Parse OBJ data from memory
pub fn parseObj(allocator: std.mem.Allocator, data: []const u8) ?ObjLoadResult {
    // First pass: count elements
    var position_count: usize = 0;
    var texcoord_count: usize = 0;
    var normal_count: usize = 0;
    var face_count: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len < 2) continue;

        if (trimmed[0] == 'v') {
            if (trimmed[1] == ' ') {
                position_count += 1;
            } else if (trimmed[1] == 't') {
                texcoord_count += 1;
            } else if (trimmed[1] == 'n') {
                normal_count += 1;
            }
        } else if (trimmed[0] == 'f' and trimmed[1] == ' ') {
            // Count face vertices to determine triangle count
            var parts = std.mem.tokenizeScalar(u8, trimmed[2..], ' ');
            var vert_count: usize = 0;
            while (parts.next()) |_| {
                vert_count += 1;
            }
            if (vert_count >= 3) {
                // Triangulate: n-gon produces n-2 triangles
                face_count += vert_count - 2;
            }
        }
    }

    if (position_count == 0) {
        logger.err("OBJ file has no vertices", .{});
        return null;
    }

    // Allocate temporary arrays for raw data
    const positions = allocator.alloc([3]f32, position_count) catch {
        logger.err("Failed to allocate positions array", .{});
        return null;
    };
    defer allocator.free(positions);

    const texcoords = if (texcoord_count > 0)
        allocator.alloc([2]f32, texcoord_count) catch {
            logger.err("Failed to allocate texcoords array", .{});
            return null;
        }
    else
        null;
    defer if (texcoords) |tc| allocator.free(tc);

    const normals = if (normal_count > 0)
        allocator.alloc([3]f32, normal_count) catch {
            logger.err("Failed to allocate normals array", .{});
            return null;
        }
    else
        null;
    defer if (normals) |n| allocator.free(n);

    // Allocate output arrays (worst case: each face vertex is unique)
    const max_vertices = face_count * 3;
    var out_vertices = allocator.alloc(math_types.Vertex3DExtended, max_vertices) catch {
        logger.err("Failed to allocate output vertices", .{});
        return null;
    };
    errdefer allocator.free(out_vertices);

    var out_indices = allocator.alloc(u32, face_count * 3) catch {
        logger.err("Failed to allocate output indices", .{});
        return null;
    };
    errdefer allocator.free(out_indices);

    // Temporary storage for sub-meshes
    var sub_mesh_list = std.ArrayList(SubMesh).init(allocator);
    defer sub_mesh_list.deinit();

    // Hash map for vertex deduplication
    var vertex_map = std.AutoHashMap(u64, u32).init(allocator);
    defer vertex_map.deinit();

    // Second pass: parse data
    var pos_idx: usize = 0;
    var tc_idx: usize = 0;
    var norm_idx: usize = 0;
    var vertex_count: u32 = 0;
    var index_count: u32 = 0;
    var current_material: []const u8 = "";
    var current_sub_mesh_start: u32 = 0;

    lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len < 2) continue;

        if (trimmed[0] == '#') continue; // Comment

        if (trimmed[0] == 'v' and trimmed[1] == ' ') {
            // Vertex position
            positions[pos_idx] = parseVec3(trimmed[2..]);
            pos_idx += 1;
        } else if (trimmed[0] == 'v' and trimmed[1] == 't') {
            // Texture coordinate
            if (texcoords) |tc| {
                tc[tc_idx] = parseVec2(trimmed[3..]);
                tc_idx += 1;
            }
        } else if (trimmed[0] == 'v' and trimmed[1] == 'n') {
            // Vertex normal
            if (normals) |n| {
                n[norm_idx] = parseVec3(trimmed[3..]);
                norm_idx += 1;
            }
        } else if (std.mem.startsWith(u8, trimmed, "usemtl ")) {
            // Material change - save current sub-mesh if any
            if (index_count > current_sub_mesh_start) {
                const mat_name = allocator.dupe(u8, current_material) catch "";
                sub_mesh_list.append(.{
                    .index_start = current_sub_mesh_start,
                    .index_count = index_count - current_sub_mesh_start,
                    .material_name = mat_name,
                }) catch {};
                current_sub_mesh_start = index_count;
            }
            current_material = trimmed[7..];
        } else if (trimmed[0] == 'f' and trimmed[1] == ' ') {
            // Face - parse and triangulate
            var face_verts: [16]FaceVertex = undefined;
            var face_vert_count: usize = 0;

            var parts = std.mem.tokenizeScalar(u8, trimmed[2..], ' ');
            while (parts.next()) |part| {
                if (face_vert_count >= 16) break;
                face_verts[face_vert_count] = parseFaceVertex(part);
                face_vert_count += 1;
            }

            if (face_vert_count < 3) continue;

            // Triangulate (fan triangulation)
            for (1..face_vert_count - 1) |i| {
                const tri_verts = [_]FaceVertex{
                    face_verts[0],
                    face_verts[i],
                    face_verts[i + 1],
                };

                for (tri_verts) |fv| {
                    // Create unique key for vertex
                    const key = (@as(u64, fv.position_idx) << 40) |
                        (@as(u64, fv.texcoord_idx) << 20) |
                        @as(u64, fv.normal_idx);

                    if (vertex_map.get(key)) |existing_idx| {
                        // Reuse existing vertex
                        out_indices[index_count] = existing_idx;
                    } else {
                        // Create new vertex
                        const pos = if (fv.position_idx > 0 and fv.position_idx <= position_count)
                            positions[fv.position_idx - 1]
                        else
                            [3]f32{ 0, 0, 0 };

                        const tc = if (texcoords) |tcs|
                            if (fv.texcoord_idx > 0 and fv.texcoord_idx <= texcoord_count)
                                tcs[fv.texcoord_idx - 1]
                            else
                                [2]f32{ 0, 0 }
                        else
                            [2]f32{ 0, 0 };

                        const norm = if (normals) |ns|
                            if (fv.normal_idx > 0 and fv.normal_idx <= normal_count)
                                ns[fv.normal_idx - 1]
                            else
                                [3]f32{ 0, 1, 0 }
                        else
                            [3]f32{ 0, 1, 0 };

                        out_vertices[vertex_count] = .{
                            .position = pos,
                            .normal = norm,
                            .texcoord = tc,
                            .tangent = .{ 1, 0, 0, 1 }, // TODO: compute proper tangent
                            .color = .{ 1, 1, 1, 1 },
                        };

                        vertex_map.put(key, vertex_count) catch {};
                        out_indices[index_count] = vertex_count;
                        vertex_count += 1;
                    }
                    index_count += 1;
                }
            }
        }
    }

    // Save final sub-mesh
    if (index_count > current_sub_mesh_start) {
        const mat_name = allocator.dupe(u8, current_material) catch "";
        sub_mesh_list.append(.{
            .index_start = current_sub_mesh_start,
            .index_count = index_count - current_sub_mesh_start,
            .material_name = mat_name,
        }) catch {};
    }

    // Shrink arrays to actual size
    const final_vertices = allocator.realloc(out_vertices, vertex_count) catch out_vertices;
    const final_indices = allocator.realloc(out_indices, index_count) catch out_indices;
    const final_sub_meshes = sub_mesh_list.toOwnedSlice() catch allocator.alloc(SubMesh, 0) catch &[_]SubMesh{};

    // Compute tangents
    computeTangents(final_vertices, final_indices);

    logger.info("OBJ loaded: {} vertices, {} indices, {} sub-meshes", .{
        vertex_count,
        index_count,
        final_sub_meshes.len,
    });

    return ObjLoadResult{
        .vertices = final_vertices,
        .indices = final_indices,
        .sub_meshes = final_sub_meshes,
        .allocator = allocator,
    };
}

fn parseVec3(str: []const u8) [3]f32 {
    var result: [3]f32 = .{ 0, 0, 0 };
    var parts = std.mem.tokenizeAny(u8, str, " \t");
    var i: usize = 0;
    while (parts.next()) |part| {
        if (i >= 3) break;
        result[i] = std.fmt.parseFloat(f32, part) catch 0;
        i += 1;
    }
    return result;
}

fn parseVec2(str: []const u8) [2]f32 {
    var result: [2]f32 = .{ 0, 0 };
    var parts = std.mem.tokenizeAny(u8, str, " \t");
    var i: usize = 0;
    while (parts.next()) |part| {
        if (i >= 2) break;
        result[i] = std.fmt.parseFloat(f32, part) catch 0;
        i += 1;
    }
    return result;
}

fn parseFaceVertex(str: []const u8) FaceVertex {
    var result = FaceVertex{
        .position_idx = 0,
        .texcoord_idx = 0,
        .normal_idx = 0,
    };

    var parts = std.mem.splitScalar(u8, str, '/');

    // Position index (always present)
    if (parts.next()) |p| {
        result.position_idx = std.fmt.parseInt(u32, p, 10) catch 0;
    }

    // Texture coordinate index (optional)
    if (parts.next()) |t| {
        if (t.len > 0) {
            result.texcoord_idx = std.fmt.parseInt(u32, t, 10) catch 0;
        }
    }

    // Normal index (optional)
    if (parts.next()) |n| {
        if (n.len > 0) {
            result.normal_idx = std.fmt.parseInt(u32, n, 10) catch 0;
        }
    }

    return result;
}

/// Compute tangent vectors for all vertices using MikkTSpace-like algorithm
fn computeTangents(vertices: []math_types.Vertex3DExtended, indices: []const u32) void {
    if (indices.len < 3) return;

    // Initialize tangents to zero for accumulation
    for (vertices) |*v| {
        v.tangent = .{ 0, 0, 0, 0 };
    }

    // Temporary storage for bitangent accumulation
    const allocator = std.heap.page_allocator;
    const bitangents = allocator.alloc([3]f32, vertices.len) catch return;
    defer allocator.free(bitangents);

    for (bitangents) |*b| {
        b.* = .{ 0, 0, 0 };
    }

    // Calculate tangent and bitangent for each triangle
    var tri_idx: usize = 0;
    while (tri_idx + 2 < indices.len) : (tri_idx += 3) {
        const idx0 = indices[tri_idx];
        const idx1 = indices[tri_idx + 1];
        const idx2 = indices[tri_idx + 2];

        const v0 = &vertices[idx0];
        const v1 = &vertices[idx1];
        const v2 = &vertices[idx2];

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
            vertices[vi].tangent[0] += tangent[0];
            vertices[vi].tangent[1] += tangent[1];
            vertices[vi].tangent[2] += tangent[2];
            bitangents[vi][0] += bitangent[0];
            bitangents[vi][1] += bitangent[1];
            bitangents[vi][2] += bitangent[2];
        }
    }

    // Orthonormalize and compute handedness
    for (vertices, 0..) |*v, idx| {
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
