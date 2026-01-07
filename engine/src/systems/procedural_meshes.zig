//! Procedural Mesh Generators
//!
//! Provides functions to generate common 3D shapes using MeshBuilder.
//! These replace the old geometry system generators with the new MeshAsset system.

const std = @import("std");
const MeshBuilder = @import("mesh_builder.zig").MeshBuilder;
const math = @import("../math/types.zig");

/// Configuration for cube generation
pub const CubeConfig = struct {
    name: []const u8,
    width: f32 = 1.0,
    height: f32 = 1.0,
    depth: f32 = 1.0,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
};

/// Configuration for sphere generation
pub const SphereConfig = struct {
    name: []const u8,
    radius: f32 = 0.5,
    rings: u32 = 16,
    sectors: u32 = 32,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
};

/// Configuration for plane generation
pub const PlaneConfig = struct {
    name: []const u8,
    width: f32 = 10.0,
    height: f32 = 10.0,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
};

/// Configuration for cone generation
pub const ConeConfig = struct {
    name: []const u8,
    radius: f32 = 0.5,
    height: f32 = 1.0,
    segments: u32 = 32,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
};

/// Configuration for cylinder generation
pub const CylinderConfig = struct {
    name: []const u8,
    radius: f32 = 0.5,
    height: f32 = 1.0,
    segments: u32 = 32,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
};

/// Generate a cube mesh using MeshBuilder
///
/// Creates a cube with the specified dimensions and color.
/// Returns error if the builder operations fail.
pub fn generateCube(allocator: std.mem.Allocator, config: CubeConfig) !MeshBuilder {
    var builder = MeshBuilder.init(allocator);
    errdefer builder.deinit();

    try builder.beginSubmesh("cube");

    const w = config.width / 2.0;
    const h = config.height / 2.0;
    const d = config.depth / 2.0;

    // Define 8 vertices of the cube
    const positions = [8][3]f32{
        .{ -w, -h, -d }, // 0: left-bottom-back
        .{ w, -h, -d }, // 1: right-bottom-back
        .{ w, h, -d }, // 2: right-top-back
        .{ -w, h, -d }, // 3: left-top-back
        .{ -w, -h, d }, // 4: left-bottom-front
        .{ w, -h, d }, // 5: right-bottom-front
        .{ w, h, d }, // 6: right-top-front
        .{ -w, h, d }, // 7: left-top-front
    };

    // Define normals for each face
    const normals = [6][3]f32{
        .{ 0, 0, -1 }, // Back
        .{ 0, 0, 1 }, // Front
        .{ -1, 0, 0 }, // Left
        .{ 1, 0, 0 }, // Right
        .{ 0, -1, 0 }, // Bottom
        .{ 0, 1, 0 }, // Top
    };

    // UVs for each corner of a face
    const uvs = [4][2]f32{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 1, 1 },
        .{ 0, 1 },
    };

    // Define 6 faces (each face has 4 vertices)
    const faces = [6][4]u8{
        .{ 1, 0, 3, 2 }, // Back
        .{ 4, 5, 6, 7 }, // Front
        .{ 0, 4, 7, 3 }, // Left
        .{ 5, 1, 2, 6 }, // Right
        .{ 4, 0, 1, 5 }, // Bottom
        .{ 3, 7, 6, 2 }, // Top
    };

    // Generate vertices and indices for each face
    for (faces, 0..) |face, face_idx| {
        const base_idx = @as(u32, @intCast(builder.vertices.items.len));

        // Add 4 vertices for this face
        for (face, 0..) |pos_idx, vert_idx| {
            const pos = positions[pos_idx];
            const vertex = math.Vertex3D{
                .position = .{ pos[0], pos[1], pos[2] },
                .normal = .{ normals[face_idx][0], normals[face_idx][1], normals[face_idx][2] },
                .texcoord = .{ uvs[vert_idx][0], uvs[vert_idx][1] },
                .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
                .tangent = .{ 1, 0, 0, 1 }, // Will be computed if needed
            };
            _ = try builder.addVertex(vertex);
        }

        // Add 2 triangles for this face (quad)
        try builder.addTriangle(base_idx + 0, base_idx + 1, base_idx + 2);
        try builder.addTriangle(base_idx + 0, base_idx + 2, base_idx + 3);
    }

    try builder.endSubmesh();
    return builder;
}

/// Generate a sphere mesh using MeshBuilder
///
/// Creates a UV sphere with the specified radius, rings, and sectors.
/// Returns error if the builder operations fail.
pub fn generateSphere(allocator: std.mem.Allocator, config: SphereConfig) !MeshBuilder {
    var builder = MeshBuilder.init(allocator);
    errdefer builder.deinit();

    try builder.beginSubmesh("sphere");

    const pi = std.math.pi;
    const R = 1.0 / @as(f32, @floatFromInt(config.rings - 1));
    const S = 1.0 / @as(f32, @floatFromInt(config.sectors - 1));

    // Generate vertices
    var r: u32 = 0;
    while (r < config.rings) : (r += 1) {
        var s: u32 = 0;
        while (s < config.sectors) : (s += 1) {
            const rf = @as(f32, @floatFromInt(r));
            const sf = @as(f32, @floatFromInt(s));

            const y = @sin(-pi / 2.0 + pi * rf * R);
            const x = @cos(2.0 * pi * sf * S) * @sin(pi * rf * R);
            const z = @sin(2.0 * pi * sf * S) * @sin(pi * rf * R);

            const vertex = math.Vertex3D{
                .position = .{
                    x * config.radius,
                    y * config.radius,
                    z * config.radius,
                },
                .normal = .{ x, y, z }, // Normal is same as normalized position for sphere
                .texcoord = .{ sf * S, rf * R },
                .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
                .tangent = .{ 1, 0, 0, 1 },
            };
            _ = try builder.addVertex(vertex);
        }
    }

    // Generate indices
    r = 0;
    while (r < config.rings - 1) : (r += 1) {
        var s: u32 = 0;
        while (s < config.sectors - 1) : (s += 1) {
            const cur_row = r * config.sectors;
            const next_row = (r + 1) * config.sectors;

            // First triangle
            try builder.addTriangle(cur_row + s, next_row + s, next_row + s + 1);
            // Second triangle
            try builder.addTriangle(cur_row + s, next_row + s + 1, cur_row + s + 1);
        }
    }

    try builder.endSubmesh();
    return builder;
}

/// Generate a plane mesh using MeshBuilder
///
/// Creates a horizontal plane (on XZ plane) with the specified dimensions.
/// Returns error if the builder operations fail.
pub fn generatePlane(allocator: std.mem.Allocator, config: PlaneConfig) !MeshBuilder {
    var builder = MeshBuilder.init(allocator);
    errdefer builder.deinit();

    try builder.beginSubmesh("plane");

    const w = config.width / 2.0;
    const h = config.height / 2.0;

    // Create 4 vertices for the plane (on XZ plane, Y = 0)
    const vertices = [4]math.Vertex3D{
        .{
            .position = .{ -w, 0, -h },
            .normal = .{ 0, 1, 0 },
            .texcoord = .{ 0, 0 },
            .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
            .tangent = .{ 1, 0, 0, 1 },
        },
        .{
            .position = .{ w, 0, -h },
            .normal = .{ 0, 1, 0 },
            .texcoord = .{ 1, 0 },
            .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
            .tangent = .{ 1, 0, 0, 1 },
        },
        .{
            .position = .{ w, 0, h },
            .normal = .{ 0, 1, 0 },
            .texcoord = .{ 1, 1 },
            .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
            .tangent = .{ 1, 0, 0, 1 },
        },
        .{
            .position = .{ -w, 0, h },
            .normal = .{ 0, 1, 0 },
            .texcoord = .{ 0, 1 },
            .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
            .tangent = .{ 1, 0, 0, 1 },
        },
    };

    // Add vertices
    for (vertices) |v| {
        _ = try builder.addVertex(v);
    }

    // Add two triangles to form a quad (front face, visible from above)
    try builder.addTriangle(0, 1, 2);
    try builder.addTriangle(0, 2, 3);

    // Add reverse-winding triangles for back face (visible from below)
    try builder.addTriangle(0, 2, 1);
    try builder.addTriangle(0, 3, 2);

    try builder.endSubmesh();
    return builder;
}

/// Generate a cone mesh using MeshBuilder
///
/// Creates a cone with the specified radius, height, and segments.
/// The cone tip is at (0, height, 0) and the base is centered at (0, 0, 0).
/// Returns error if the builder operations fail.
pub fn generateCone(allocator: std.mem.Allocator, config: ConeConfig) !MeshBuilder {
    var builder = MeshBuilder.init(allocator);
    errdefer builder.deinit();

    try builder.beginSubmesh("cone");

    const pi = std.math.pi;
    const half_height = config.height / 2.0;

    // Add apex vertex (top of cone)
    const apex = math.Vertex3D{
        .position = .{ 0, half_height, 0 },
        .normal = .{ 0, 1, 0 },
        .texcoord = .{ 0.5, 0.5 },
        .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
        .tangent = .{ 1, 0, 0, 1 },
    };
    const apex_idx = try builder.addVertex(apex);

    // Add center vertex for base
    const base_center = math.Vertex3D{
        .position = .{ 0, -half_height, 0 },
        .normal = .{ 0, -1, 0 },
        .texcoord = .{ 0.5, 0.5 },
        .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
        .tangent = .{ 1, 0, 0, 1 },
    };
    const base_center_idx = try builder.addVertex(base_center);

    // Generate base vertices and side vertices
    var seg: u32 = 0;
    while (seg <= config.segments) : (seg += 1) {
        const angle = 2.0 * pi * @as(f32, @floatFromInt(seg)) / @as(f32, @floatFromInt(config.segments));
        const x = @cos(angle) * config.radius;
        const z = @sin(angle) * config.radius;

        // Base vertex (for base cap)
        const base_vertex = math.Vertex3D{
            .position = .{ x, -half_height, z },
            .normal = .{ 0, -1, 0 },
            .texcoord = .{ (@cos(angle) + 1.0) / 2.0, (@sin(angle) + 1.0) / 2.0 },
            .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
            .tangent = .{ 1, 0, 0, 1 },
        };
        _ = try builder.addVertex(base_vertex);

        // Side vertex (for cone surface)
        const dx = x;
        const dy = config.radius; // Slope of cone
        const dz = z;
        const len = @sqrt(dx * dx + dy * dy + dz * dz);
        const side_vertex = math.Vertex3D{
            .position = .{ x, -half_height, z },
            .normal = .{ dx / len, dy / len, dz / len },
            .texcoord = .{ @as(f32, @floatFromInt(seg)) / @as(f32, @floatFromInt(config.segments)), 0 },
            .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
            .tangent = .{ 1, 0, 0, 1 },
        };
        _ = try builder.addVertex(side_vertex);
    }

    // Generate indices for base cap (viewed from below, winding should be CCW)
    seg = 0;
    while (seg < config.segments) : (seg += 1) {
        const base_start = 2; // After apex and base_center
        const current_base = base_start + seg * 2;
        const next_base = base_start + ((seg + 1) % (config.segments + 1)) * 2;
        try builder.addTriangle(base_center_idx, current_base, next_base);
    }

    // Generate indices for cone sides (viewed from outside, winding should be CCW)
    seg = 0;
    while (seg < config.segments) : (seg += 1) {
        const base_start = 2;
        const current_side = base_start + seg * 2 + 1;
        const next_side = base_start + ((seg + 1) % (config.segments + 1)) * 2 + 1;
        try builder.addTriangle(apex_idx, next_side, current_side);
    }

    try builder.endSubmesh();
    return builder;
}

/// Generate a cylinder mesh using MeshBuilder
///
/// Creates a cylinder with the specified radius, height, and segments.
/// The cylinder is centered at the origin.
/// Returns error if the builder operations fail.
pub fn generateCylinder(allocator: std.mem.Allocator, config: CylinderConfig) !MeshBuilder {
    var builder = MeshBuilder.init(allocator);
    errdefer builder.deinit();

    try builder.beginSubmesh("cylinder");

    const pi = std.math.pi;
    const half_height = config.height / 2.0;

    // Add center vertices for top and bottom caps
    const top_center = math.Vertex3D{
        .position = .{ 0, half_height, 0 },
        .normal = .{ 0, 1, 0 },
        .texcoord = .{ 0.5, 0.5 },
        .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
        .tangent = .{ 1, 0, 0, 1 },
    };
    const top_center_idx = try builder.addVertex(top_center);

    const bottom_center = math.Vertex3D{
        .position = .{ 0, -half_height, 0 },
        .normal = .{ 0, -1, 0 },
        .texcoord = .{ 0.5, 0.5 },
        .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
        .tangent = .{ 1, 0, 0, 1 },
    };
    const bottom_center_idx = try builder.addVertex(bottom_center);

    // Generate vertices for caps and sides
    var seg: u32 = 0;
    while (seg <= config.segments) : (seg += 1) {
        const angle = 2.0 * pi * @as(f32, @floatFromInt(seg)) / @as(f32, @floatFromInt(config.segments));
        const x = @cos(angle) * config.radius;
        const z = @sin(angle) * config.radius;

        // Top cap vertex
        const top_cap = math.Vertex3D{
            .position = .{ x, half_height, z },
            .normal = .{ 0, 1, 0 },
            .texcoord = .{ (@cos(angle) + 1.0) / 2.0, (@sin(angle) + 1.0) / 2.0 },
            .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
            .tangent = .{ 1, 0, 0, 1 },
        };
        _ = try builder.addVertex(top_cap);

        // Top side vertex
        const top_side = math.Vertex3D{
            .position = .{ x, half_height, z },
            .normal = .{ x / config.radius, 0, z / config.radius },
            .texcoord = .{ @as(f32, @floatFromInt(seg)) / @as(f32, @floatFromInt(config.segments)), 1 },
            .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
            .tangent = .{ 1, 0, 0, 1 },
        };
        _ = try builder.addVertex(top_side);

        // Bottom cap vertex
        const bottom_cap = math.Vertex3D{
            .position = .{ x, -half_height, z },
            .normal = .{ 0, -1, 0 },
            .texcoord = .{ (@cos(angle) + 1.0) / 2.0, (@sin(angle) + 1.0) / 2.0 },
            .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
            .tangent = .{ 1, 0, 0, 1 },
        };
        _ = try builder.addVertex(bottom_cap);

        // Bottom side vertex
        const bottom_side = math.Vertex3D{
            .position = .{ x, -half_height, z },
            .normal = .{ x / config.radius, 0, z / config.radius },
            .texcoord = .{ @as(f32, @floatFromInt(seg)) / @as(f32, @floatFromInt(config.segments)), 0 },
            .color = .{ config.color[0], config.color[1], config.color[2], 1.0 },
            .tangent = .{ 1, 0, 0, 1 },
        };
        _ = try builder.addVertex(bottom_side);
    }

    // Generate indices
    seg = 0;
    while (seg < config.segments) : (seg += 1) {
        const base_start = 2; // After two center vertices
        const stride = 4; // 4 vertices per segment
        const current = base_start + seg * stride;
        const next = base_start + ((seg + 1) % (config.segments + 1)) * stride;

        // Top cap (viewed from above, winding should be CCW)
        try builder.addTriangle(top_center_idx, next, current);

        // Bottom cap (viewed from below, winding should be CCW)
        try builder.addTriangle(bottom_center_idx, current + 2, next + 2);

        // Side faces (viewed from outside, winding should be CCW)
        // Two triangles per segment forming a quad
        try builder.addTriangle(current + 1, next + 3, current + 3);
        try builder.addTriangle(current + 1, next + 1, next + 3);
    }

    try builder.endSubmesh();
    return builder;
}
