const std = @import("std");

pub const Vec2 = extern union {
    elements: [2]f32,

    xy: extern struct {
        x: f32,
        y: f32,
    },

    rg: extern struct {
        r: f32,
        g: f32,
    },

    st: extern struct {
        s: f32,
        t: f32,
    },

    uv: extern struct {
        u: f32,
        v: f32,
    },
};

pub const Vec3 = extern union {
    elements: [3]f32,

    xyz: extern struct {
        x: f32,
        y: f32,
        z: f32,
    },

    rgb: extern struct {
        r: f32,
        g: f32,
        b: f32,
    },

    stp: extern struct {
        s: f32,
        t: f32,
        p: f32,
    },

    uvw: extern struct {
        u: f32,
        v: f32,
        w: f32,
    },
};

pub const use_simd = false; // set via build.zig if needed

pub const Vec4 = extern union {
    elements: [4]f32 align(16),

    xyzw: extern struct {
        x: f32,
        y: f32,
        z: f32,
        w: f32,
    },

    rgba: extern struct {
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    },

    stpq: extern struct {
        s: f32,
        t: f32,
        p: f32,
        q: f32,
    },

    simd: if (use_simd) @Vector(4, f32) else void,
};

pub const Quat = Vec4;

pub const Mat4 = extern union {
    data: [16]f32,
};

/// Vertex with position, color, and texture coordinates for rendering (32 bytes)
pub const Vertex3D = extern struct {
    position: [3]f32, // vec3 position
    color: [3]f32, // vec3 color
    texcoord: [2]f32, // vec2 texture coordinates
};

/// Extended vertex format for PBR and normal mapping (64 bytes)
/// Used for: PBR materials, normal mapping, advanced lighting
pub const Vertex3DExtended = extern struct {
    position: [3]f32, // 12 bytes - vec3 position
    normal: [3]f32, // 12 bytes - vec3 normal
    texcoord: [2]f32, // 8 bytes - vec2 texture coordinates
    tangent: [4]f32, // 16 bytes - vec4 tangent (w = handedness)
    color: [4]f32, // 16 bytes - vec4 color (RGBA)
};
