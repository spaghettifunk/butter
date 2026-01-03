const std = @import("std");
const types = @import("types.zig");

pub const Vec2 = types.Vec2;
pub const Vec3 = types.Vec3;
pub const Vec4 = types.Vec4;
pub const Quat = types.Quat;
pub const Mat4 = types.Mat4;
pub const Vertex3D = types.Vertex3D;

// -------------------------------------------------
// Constants
// -------------------------------------------------

pub const K_PI: f32 = 3.14159265358979323846;
pub const K_PI_2: f32 = 2.0 * K_PI;
pub const K_HALF_PI: f32 = 0.5 * K_PI;
pub const K_QUARTER_PI: f32 = 0.25 * K_PI;
pub const K_ONE_OVER_PI: f32 = 1.0 / K_PI;
pub const K_ONE_OVER_TWO_PI: f32 = 1.0 / K_PI_2;
pub const K_SQRT_TWO: f32 = 1.41421356237309504880;
pub const K_SQRT_THREE: f32 = 1.73205080756887729352;
pub const K_SQRT_ONE_OVER_TWO: f32 = 0.70710678118654752440;
pub const K_SQRT_ONE_OVER_THREE: f32 = 0.57735026918962576450;
pub const K_DEG2RAD_MULTIPLIER: f32 = K_PI / 180.0;
pub const K_RAD2DEG_MULTIPLIER: f32 = 180.0 / K_PI;

pub const K_SEC_TO_MS_MULTIPLIER: f32 = 1000.0;
pub const K_MS_TO_SEC_MULTIPLIER: f32 = 0.001;

pub const K_INFINITY: f32 = 1e30;
pub const K_FLOAT_EPSILON: f32 = 1.192092896e-07;

// -------------------------------------------------
// General math functions
// -------------------------------------------------

pub inline fn bsin(x: f32) f32 {
    return std.math.sin(x);
}

pub inline fn bcos(x: f32) f32 {
    return std.math.cos(x);
}

pub inline fn btan(x: f32) f32 {
    return std.math.tan(x);
}

pub inline fn bacos(x: f32) f32 {
    return std.math.acos(x);
}

pub inline fn bsqrt(x: f32) f32 {
    return std.math.sqrt(x);
}

pub inline fn babs(x: f32) f32 {
    return @abs(x);
}

pub inline fn isPowerOf2(value: u64) bool {
    return value != 0 and (value & (value - 1)) == 0;
}

// NOTE: Zig does not have a global RNG by default.
// These mirror semantics but use std.rand.

pub fn brandom() i32 {
    return @intCast(std.crypto.random.int(i32));
}

pub fn brandomInRange(min: i32, max: i32) i32 {
    return min + @mod(brandom(), max - min + 1);
}

pub fn fbrandom() f32 {
    return std.crypto.random.float(f32);
}

pub fn fbrandomInRange(min: f32, max: f32) f32 {
    return min + (max - min) * fbrandom();
}

// -------------------------------------------------
// Vector 2
// -------------------------------------------------

pub inline fn vec2Create(x: f32, y: f32) Vec2 {
    return .{ .xy = .{ .x = x, .y = y } };
}

pub inline fn vec2Zero() Vec2 {
    return .{ .elements = .{ 0.0, 0.0 } };
}

pub inline fn vec2One() Vec2 {
    return .{ .elements = .{ 1.0, 1.0 } };
}

pub inline fn vec2Up() Vec2 {
    return .{ .elements = .{ 0.0, 1.0 } };
}

pub inline fn vec2Down() Vec2 {
    return .{ .elements = .{ 0.0, -1.0 } };
}

pub inline fn vec2Left() Vec2 {
    return .{ .elements = .{ -1.0, 0.0 } };
}

pub inline fn vec2Right() Vec2 {
    return .{ .elements = .{ 1.0, 0.0 } };
}

pub inline fn vec2Add(a: Vec2, b: Vec2) Vec2 {
    return .{ .elements = .{ a.elements[0] + b.elements[0], a.elements[1] + b.elements[1] } };
}

pub inline fn vec2Sub(a: Vec2, b: Vec2) Vec2 {
    return .{ .elements = .{ a.elements[0] - b.elements[0], a.elements[1] - b.elements[1] } };
}

pub inline fn vec2Mul(a: Vec2, b: Vec2) Vec2 {
    return .{ .elements = .{ a.elements[0] * b.elements[0], a.elements[1] * b.elements[1] } };
}

pub inline fn vec2Div(a: Vec2, b: Vec2) Vec2 {
    return .{ .elements = .{ a.elements[0] / b.elements[0], a.elements[1] / b.elements[1] } };
}

pub inline fn vec2LengthSquared(v: Vec2) f32 {
    return v.elements[0] * v.elements[0] + v.elements[1] * v.elements[1];
}

pub inline fn vec2Length(v: Vec2) f32 {
    return bsqrt(vec2LengthSquared(v));
}

pub inline fn vec2Normalize(v: *Vec2) void {
    const len = vec2Length(v.*);
    v.elements[0] /= len;
    v.elements[1] /= len;
}

pub inline fn vec2Normalized(v: Vec2) Vec2 {
    var out = v;
    vec2Normalize(&out);
    return out;
}

pub inline fn vec2Compare(a: Vec2, b: Vec2, tolerance: f32) bool {
    return babs(a.elements[0] - b.elements[0]) <= tolerance and
        babs(a.elements[1] - b.elements[1]) <= tolerance;
}

pub inline fn vec2Distance(a: Vec2, b: Vec2) f32 {
    return vec2Length(vec2Sub(a, b));
}

// -------------------------------------------------
// Vector 3
// -------------------------------------------------

pub inline fn vec3Create(x: f32, y: f32, z: f32) Vec3 {
    return .{ .elements = .{ x, y, z } };
}

pub inline fn vec3FromVec4(v: Vec4) Vec3 {
    return .{ .elements = .{ v.elements[0], v.elements[1], v.elements[2] } };
}

pub inline fn vec3ToVec4(v: Vec3, w: f32) Vec4 {
    return .{ .elements = .{ v.elements[0], v.elements[1], v.elements[2], w } };
}

pub inline fn vec3Zero() Vec3 {
    return .{ .elements = .{ 0.0, 0.0, 0.0 } };
}

pub inline fn vec3One() Vec3 {
    return .{ .elements = .{ 1.0, 1.0, 1.0 } };
}

pub inline fn vec3Add(a: Vec3, b: Vec3) Vec3 {
    return .{ .elements = .{
        a.elements[0] + b.elements[0],
        a.elements[1] + b.elements[1],
        a.elements[2] + b.elements[2],
    } };
}

pub inline fn vec3Sub(a: Vec3, b: Vec3) Vec3 {
    return .{ .elements = .{
        a.elements[0] - b.elements[0],
        a.elements[1] - b.elements[1],
        a.elements[2] - b.elements[2],
    } };
}

pub inline fn vec3MulScalar(v: Vec3, s: f32) Vec3 {
    return .{ .elements = .{
        v.elements[0] * s,
        v.elements[1] * s,
        v.elements[2] * s,
    } };
}

pub inline fn vec3LengthSquared(v: Vec3) f32 {
    return v.elements[0] * v.elements[0] +
        v.elements[1] * v.elements[1] +
        v.elements[2] * v.elements[2];
}

pub inline fn vec3Length(v: Vec3) f32 {
    return bsqrt(vec3LengthSquared(v));
}

pub inline fn vec3Normalize(v: *Vec3) void {
    const len = vec3Length(v.*);
    v.elements[0] /= len;
    v.elements[1] /= len;
    v.elements[2] /= len;
}

pub inline fn vec3Normalized(v: Vec3) Vec3 {
    var out = v;
    vec3Normalize(&out);
    return out;
}

pub inline fn vec3Dot(a: Vec3, b: Vec3) f32 {
    return a.elements[0] * b.elements[0] +
        a.elements[1] * b.elements[1] +
        a.elements[2] * b.elements[2];
}

pub inline fn vec3Cross(a: Vec3, b: Vec3) Vec3 {
    return .{ .elements = .{
        a.elements[1] * b.elements[2] - a.elements[2] * b.elements[1],
        a.elements[2] * b.elements[0] - a.elements[0] * b.elements[2],
        a.elements[0] * b.elements[1] - a.elements[1] * b.elements[0],
    } };
}

// -------------------------------------------------
// Vector 4
// -------------------------------------------------

pub inline fn vec4Create(x: f32, y: f32, z: f32, w: f32) Vec4 {
    return .{ .elements = .{ x, y, z, w } };
}

pub inline fn vec4Zero() Vec4 {
    return .{ .elements = .{ 0.0, 0.0, 0.0, 0.0 } };
}

pub inline fn vec4One() Vec4 {
    return .{ .elements = .{ 1.0, 1.0, 1.0, 1.0 } };
}

pub inline fn vec4Add(a: Vec4, b: Vec4) Vec4 {
    return .{ .elements = .{
        a.elements[0] + b.elements[0],
        a.elements[1] + b.elements[1],
        a.elements[2] + b.elements[2],
        a.elements[3] + b.elements[3],
    } };
}

pub inline fn vec4LengthSquared(v: Vec4) f32 {
    return v.elements[0] * v.elements[0] +
        v.elements[1] * v.elements[1] +
        v.elements[2] * v.elements[2] +
        v.elements[3] * v.elements[3];
}

pub inline fn vec4Length(v: Vec4) f32 {
    return bsqrt(vec4LengthSquared(v));
}

pub inline fn vec4Normalize(v: *Vec4) void {
    const len = vec4Length(v.*);
    inline for (0..4) |i| {
        v.elements[i] /= len;
    }
}

pub inline fn vec4Normalized(v: Vec4) Vec4 {
    var out = v;
    vec4Normalize(&out);
    return out;
}

pub inline fn vec4DotF32(
    a0: f32,
    a1: f32,
    a2: f32,
    a3: f32,
    b0: f32,
    b1: f32,
    b2: f32,
    b3: f32,
) f32 {
    return a0 * b0 + a1 * b1 + a2 * b2 + a3 * b3;
}

// -------------------------------------------------
// Mat4
// -------------------------------------------------

pub inline fn mat4Identity() Mat4 {
    var out: Mat4 = .{ .data = [_]f32{0} ** 16 };
    out.data[0] = 1.0;
    out.data[5] = 1.0;
    out.data[10] = 1.0;
    out.data[15] = 1.0;
    return out;
}

pub inline fn mat4Mul(a: Mat4, b: Mat4) Mat4 {
    var out = mat4Identity();

    var m1_ptr: usize = 0;
    var dst_ptr: usize = 0;

    for (0..4) |_| {
        for (0..4) |j| {
            out.data[dst_ptr] =
                a.data[m1_ptr + 0] * b.data[0 + j] +
                a.data[m1_ptr + 1] * b.data[4 + j] +
                a.data[m1_ptr + 2] * b.data[8 + j] +
                a.data[m1_ptr + 3] * b.data[12 + j];
            dst_ptr += 1;
        }
        m1_ptr += 4;
    }

    return out;
}

pub inline fn mat4Orthographic(
    left: f32,
    right: f32,
    bottom: f32,
    top: f32,
    near_clip: f32,
    far_clip: f32,
) Mat4 {
    var out = mat4Identity();

    const lr = 1.0 / (left - right);
    const bt = 1.0 / (bottom - top);
    const nf = 1.0 / (near_clip - far_clip);

    out.data[0] = -2.0 * lr;
    out.data[5] = -2.0 * bt;
    out.data[10] = 2.0 * nf;

    out.data[12] = (left + right) * lr;
    out.data[13] = (top + bottom) * bt;
    out.data[14] = (far_clip + near_clip) * nf;

    return out;
}

pub inline fn mat4Perspective(
    fov_radians: f32,
    aspect_ratio: f32,
    near_clip: f32,
    far_clip: f32,
) Mat4 {
    const half_tan_fov = std.math.tan(fov_radians * 0.5);

    var out: Mat4 = .{ .data = [_]f32{0} ** 16 };
    out.data[0] = 1.0 / (aspect_ratio * half_tan_fov);
    out.data[5] = 1.0 / half_tan_fov;
    out.data[10] = -((far_clip + near_clip) / (far_clip - near_clip));
    out.data[11] = -1.0;
    out.data[14] = -((2.0 * far_clip * near_clip) / (far_clip - near_clip));
    return out;
}

pub inline fn mat4LookAt(position: Vec3, target: Vec3, up: Vec3) Mat4 {
    var z = Vec3{ .elements = .{
        target.elements[0] - position.elements[0],
        target.elements[1] - position.elements[1],
        target.elements[2] - position.elements[2],
    } };
    z = vec3Normalized(z);

    const x = vec3Normalized(vec3Cross(z, up));
    const y = vec3Cross(x, z);

    var out: Mat4 = undefined;

    out.data[0] = x.elements[0];
    out.data[1] = y.elements[0];
    out.data[2] = -z.elements[0];
    out.data[3] = 0;

    out.data[4] = x.elements[1];
    out.data[5] = y.elements[1];
    out.data[6] = -z.elements[1];
    out.data[7] = 0;

    out.data[8] = x.elements[2];
    out.data[9] = y.elements[2];
    out.data[10] = -z.elements[2];
    out.data[11] = 0;

    out.data[12] = -vec3Dot(x, position);
    out.data[13] = -vec3Dot(y, position);
    out.data[14] = vec3Dot(z, position);
    out.data[15] = 1.0;

    return out;
}

pub inline fn mat4Translation(x: f32, y: f32, z: f32) Mat4 {
    var out = mat4Identity();
    out.data[12] = x;
    out.data[13] = y;
    out.data[14] = z;
    return out;
}

pub inline fn mat4RotationX(angle_radians: f32) Mat4 {
    var out = mat4Identity();
    const c = bcos(angle_radians);
    const s = bsin(angle_radians);
    out.data[5] = c;
    out.data[6] = s;
    out.data[9] = -s;
    out.data[10] = c;
    return out;
}

pub inline fn mat4RotationY(angle_radians: f32) Mat4 {
    var out = mat4Identity();
    const c = bcos(angle_radians);
    const s = bsin(angle_radians);
    out.data[0] = c;
    out.data[2] = -s;
    out.data[8] = s;
    out.data[10] = c;
    return out;
}

pub inline fn mat4RotationZ(angle_radians: f32) Mat4 {
    var out = mat4Identity();
    const c = bcos(angle_radians);
    const s = bsin(angle_radians);
    out.data[0] = c;
    out.data[1] = s;
    out.data[4] = -s;
    out.data[5] = c;
    return out;
}

/// Combined rotation around Y then X axis (common for camera-like rotation)
pub inline fn mat4RotationYX(angle_y: f32, angle_x: f32) Mat4 {
    return mat4Mul(mat4RotationY(angle_y), mat4RotationX(angle_x));
}

pub inline fn mat4Left(matrix: Mat4) Vec3 {
    var left: Vec3 = undefined;
    left.x = -matrix.data[0];
    left.y = -matrix.data[4];
    left.z = -matrix.data[8];
    vec3Normalize(&left);
    return left;
}

pub inline fn mat4Right(matrix: Mat4) Vec3 {
    var right: Vec3 = undefined;
    right.x = matrix.data[0];
    right.y = matrix.data[4];
    right.z = matrix.data[8];
    vec3Normalize(&right);
    return right;
}

pub inline fn mat4Inverse(matrix: Mat4) Mat4 {
    const m = matrix.data;

    const t0: f32 = m[10] * m[15];
    const t1: f32 = m[14] * m[11];
    const t2: f32 = m[6] * m[15];
    const t3: f32 = m[14] * m[7];
    const t4: f32 = m[6] * m[11];
    const t5: f32 = m[10] * m[7];
    const t6: f32 = m[2] * m[15];
    const t7: f32 = m[14] * m[3];
    const t8: f32 = m[2] * m[11];
    const t9: f32 = m[10] * m[3];
    const t10: f32 = m[2] * m[7];
    const t11: f32 = m[6] * m[3];
    const t12: f32 = m[8] * m[13];
    const t13: f32 = m[12] * m[9];
    const t14: f32 = m[4] * m[13];
    const t15: f32 = m[12] * m[5];
    const t16: f32 = m[4] * m[9];
    const t17: f32 = m[8] * m[5];
    const t18: f32 = m[0] * m[13];
    const t19: f32 = m[12] * m[1];
    const t20: f32 = m[0] * m[9];
    const t21: f32 = m[8] * m[1];
    const t22: f32 = m[0] * m[5];
    const t23: f32 = m[4] * m[1];

    var out_matrix: Mat4 = undefined;
    const o = &out_matrix.data;

    o[0] = (t0 * m[5] + t3 * m[9] + t4 * m[13]) - (t1 * m[5] + t2 * m[9] + t5 * m[13]);
    o[1] = (t1 * m[1] + t6 * m[9] + t9 * m[13]) - (t0 * m[1] + t7 * m[9] + t8 * m[13]);
    o[2] = (t2 * m[1] + t7 * m[5] + t10 * m[13]) - (t3 * m[1] + t6 * m[5] + t11 * m[13]);
    o[3] = (t5 * m[1] + t8 * m[5] + t11 * m[9]) - (t4 * m[1] + t9 * m[5] + t10 * m[9]);

    const d: f32 = 1.0 / (m[0] * o[0] + m[4] * o[1] + m[8] * o[2] + m[12] * o[3]);

    o[0] = d * o[0];
    o[1] = d * o[1];
    o[2] = d * o[2];
    o[3] = d * o[3];
    o[4] = d * ((t1 * m[4] + t2 * m[8] + t5 * m[12]) - (t0 * m[4] + t3 * m[8] + t4 * m[12]));
    o[5] = d * ((t0 * m[0] + t7 * m[8] + t8 * m[12]) - (t1 * m[0] + t6 * m[8] + t9 * m[12]));
    o[6] = d * ((t3 * m[0] + t6 * m[4] + t11 * m[12]) - (t2 * m[0] + t7 * m[4] + t10 * m[12]));
    o[7] = d * ((t4 * m[0] + t9 * m[4] + t10 * m[8]) - (t5 * m[0] + t8 * m[4] + t11 * m[8]));
    o[8] = d * ((t12 * m[7] + t15 * m[11] + t16 * m[15]) - (t13 * m[7] + t14 * m[11] + t17 * m[15]));
    o[9] = d * ((t13 * m[3] + t18 * m[11] + t21 * m[15]) - (t12 * m[3] + t19 * m[11] + t20 * m[15]));
    o[10] = d * ((t14 * m[3] + t19 * m[7] + t22 * m[15]) - (t15 * m[3] + t18 * m[7] + t23 * m[15]));
    o[11] = d * ((t17 * m[3] + t20 * m[7] + t23 * m[11]) - (t16 * m[3] + t21 * m[7] + t22 * m[11]));
    o[12] = d * ((t14 * m[10] + t17 * m[14] + t13 * m[6]) - (t16 * m[14] + t12 * m[6] + t15 * m[10]));
    o[13] = d * ((t20 * m[14] + t12 * m[2] + t19 * m[10]) - (t18 * m[10] + t21 * m[14] + t13 * m[2]));
    o[14] = d * ((t18 * m[6] + t23 * m[14] + t15 * m[2]) - (t22 * m[14] + t14 * m[2] + t19 * m[6]));
    o[15] = d * ((t22 * m[10] + t16 * m[2] + t21 * m[6]) - (t20 * m[6] + t23 * m[10] + t17 * m[2]));

    return out_matrix;
}

// -------------------------------------------------
// Quaternion
// -------------------------------------------------

pub inline fn quatIdentity() Quat {
    return .{ .x = 0, .y = 0, .z = 0, .w = 1.0 };
}

pub inline fn quatNormal(q: Quat) f32 {
    return std.math.sqrt(
        q.x * q.x +
            q.y * q.y +
            q.z * q.z +
            q.w * q.w,
    );
}

pub inline fn quatNormalize(q: Quat) Quat {
    const n = quatNormal(q);
    return .{
        .x = q.x / n,
        .y = q.y / n,
        .z = q.z / n,
        .w = q.w / n,
    };
}

pub inline fn quatConjugate(q: Quat) Quat {
    return .{
        .x = -q.x,
        .y = -q.y,
        .z = -q.z,
        .w = q.w,
    };
}

pub inline fn quatInverse(q: Quat) Quat {
    return quatNormalize(quatConjugate(q));
}

pub inline fn quatMul(a: Quat, b: Quat) Quat {
    return .{
        .x = a.x * b.w + a.y * b.z - a.z * b.y + a.w * b.x,
        .y = -a.x * b.z + a.y * b.w + a.z * b.x + a.w * b.y,
        .z = a.x * b.y - a.y * b.x + a.z * b.w + a.w * b.z,
        .w = -a.x * b.x - a.y * b.y - a.z * b.z + a.w * b.w,
    };
}

pub inline fn quatDot(a: Quat, b: Quat) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
}

pub inline fn quatToMat4(q: Quat) Mat4 {
    var out = mat4Identity();

    // Normalize to avoid drift
    const n = quatNormalize(q);

    out.data[0] = 1.0 - 2.0 * n.y * n.y - 2.0 * n.z * n.z;
    out.data[1] = 2.0 * n.x * n.y - 2.0 * n.z * n.w;
    out.data[2] = 2.0 * n.x * n.z + 2.0 * n.y * n.w;

    out.data[4] = 2.0 * n.x * n.y + 2.0 * n.z * n.w;
    out.data[5] = 1.0 - 2.0 * n.x * n.x - 2.0 * n.z * n.z;
    out.data[6] = 2.0 * n.y * n.z - 2.0 * n.x * n.w;

    out.data[8] = 2.0 * n.x * n.z - 2.0 * n.y * n.w;
    out.data[9] = 2.0 * n.y * n.z + 2.0 * n.x * n.w;
    out.data[10] = 1.0 - 2.0 * n.x * n.x - 2.0 * n.y * n.y;

    return out;
}

pub inline fn quatToRotationMatrix(q: Quat, center: Vec3) Mat4 {
    var out: Mat4 = undefined;
    var o = &out.data;

    o[0] = (q.x * q.x) - (q.y * q.y) - (q.z * q.z) + (q.w * q.w);
    o[1] = 2.0 * ((q.x * q.y) + (q.z * q.w));
    o[2] = 2.0 * ((q.x * q.z) - (q.y * q.w));
    o[3] = center.x - center.x * o[0] - center.y * o[1] - center.z * o[2];

    o[4] = 2.0 * ((q.x * q.y) - (q.z * q.w));
    o[5] = -(q.x * q.x) + (q.y * q.y) - (q.z * q.z) + (q.w * q.w);
    o[6] = 2.0 * ((q.y * q.z) + (q.x * q.w));
    o[7] = center.y - center.x * o[4] - center.y * o[5] - center.z * o[6];

    o[8] = 2.0 * ((q.x * q.z) + (q.y * q.w));
    o[9] = 2.0 * ((q.y * q.z) - (q.x * q.w));
    o[10] = -(q.x * q.x) - (q.y * q.y) + (q.z * q.z) + (q.w * q.w);
    o[11] = center.z - center.x * o[8] - center.y * o[9] - center.z * o[10];

    o[12] = 0.0;
    o[13] = 0.0;
    o[14] = 0.0;
    o[15] = 1.0;

    return out;
}

pub inline fn quatFromAxisAngle(axis: Vec3, angle: f32, normalize: bool) Quat {
    const half_angle = 0.5 * angle;
    const s = std.math.sin(half_angle);
    const c = std.math.cos(half_angle);

    const q = Quat{
        .x = s * axis.x,
        .y = s * axis.y,
        .z = s * axis.z,
        .w = c,
    };

    if (normalize) {
        return quatNormalize(q);
    }
    return q;
}

pub inline fn quatSlerp(q0: Quat, q1: Quat, percentage: f32) Quat {
    const v0 = quatNormalize(q0);
    var v1 = quatNormalize(q1);

    var dot = quatDot(v0, v1);

    // Take shortest path
    if (dot < 0.0) {
        v1.x = -v1.x;
        v1.y = -v1.y;
        v1.z = -v1.z;
        v1.w = -v1.w;
        dot = -dot;
    }

    const DOT_THRESHOLD: f32 = 0.9995;
    if (dot > DOT_THRESHOLD) {
        const result = Quat{
            .x = v0.x + (v1.x - v0.x) * percentage,
            .y = v0.y + (v1.y - v0.y) * percentage,
            .z = v0.z + (v1.z - v0.z) * percentage,
            .w = v0.w + (v1.w - v0.w) * percentage,
        };
        return quatNormalize(result);
    }

    const theta_0 = std.math.acos(dot);
    const theta = theta_0 * percentage;

    const sin_theta = std.math.sin(theta);
    const sin_theta_0 = std.math.sin(theta_0);

    const s0 = std.math.cos(theta) - dot * sin_theta / sin_theta_0;
    const s1 = sin_theta / sin_theta_0;

    return Quat{
        .x = v0.x * s0 + v1.x * s1,
        .y = v0.y * s0 + v1.y * s1,
        .z = v0.z * s0 + v1.z * s1,
        .w = v0.w * s0 + v1.w * s1,
    };
}

pub inline fn degToRad(deg: f32) f32 {
    return deg * std.math.pi / 180.0;
}

pub inline fn radToDeg(rad: f32) f32 {
    return rad * 180.0 / std.math.pi;
}

// -------------------------------------------------
// Direction <-> Euler Angle Conversion
// -------------------------------------------------

/// Convert a direction vector to Euler angles (in degrees)
/// Uses YXZ rotation order to match engine convention
/// Returns pitch (X), yaw (Y), roll (Z=0)
pub fn directionToEuler(direction: [3]f32) [3]f32 {
    // Normalize direction
    var dir_vec = Vec3{ .elements = direction };
    vec3Normalize(&dir_vec);
    const d = dir_vec.elements;

    // Calculate horizontal distance (xz plane projection)
    const xz_len = @sqrt(d[0] * d[0] + d[2] * d[2]);

    // Handle singularity when looking straight up or down
    const epsilon: f32 = 0.001;
    if (xz_len < epsilon) {
        // Looking straight up or down - yaw is undefined, use 0 as convention
        const pitch_singular: f32 = if (d[1] < 0) 90.0 else -90.0;
        return .{ pitch_singular, 0.0, 0.0 };
    }

    // Calculate pitch (rotation around X axis)
    // pitch = atan2(-dy, sqrt(dx² + dz²))
    const pitch = std.math.atan2(-d[1], xz_len);

    // Calculate yaw (rotation around Y axis)
    // yaw = atan2(dx, dz)
    const yaw = std.math.atan2(d[0], d[2]);

    // Roll is always 0 for direction vectors (no twist component)
    const roll: f32 = 0.0;

    // Convert to degrees
    return .{
        pitch * K_RAD2DEG_MULTIPLIER,
        yaw * K_RAD2DEG_MULTIPLIER,
        roll,
    };
}

/// Convert Euler angles (in degrees) to a direction vector
/// Uses YXZ rotation order to match engine convention
/// Returns normalized direction vector
pub fn eulerToDirection(euler: [3]f32) [3]f32 {
    // Convert to radians
    const pitch = euler[0] * K_DEG2RAD_MULTIPLIER;
    const yaw = euler[1] * K_DEG2RAD_MULTIPLIER;
    // Ignore roll (euler[2]) for direction vectors

    // Calculate direction components
    const cos_pitch = bcos(pitch);
    const sin_pitch = bsin(pitch);
    const cos_yaw = bcos(yaw);
    const sin_yaw = bsin(yaw);

    // Direction = (sin_yaw * cos_pitch, -sin_pitch, cos_yaw * cos_pitch)
    const direction = [3]f32{
        sin_yaw * cos_pitch,
        -sin_pitch,
        cos_yaw * cos_pitch,
    };

    // Normalize to ensure unit vector
    var dir_vec = Vec3{ .elements = direction };
    vec3Normalize(&dir_vec);
    return dir_vec.elements;
}
