//! Picking System
//! Provides ray casting and intersection tests for object selection.

const std = @import("std");
const math = @import("../math/math.zig");
const editor_scene = @import("editor_scene.zig");

const EditorScene = editor_scene.EditorScene;
const EditorObjectId = editor_scene.EditorObjectId;
const INVALID_OBJECT_ID = editor_scene.INVALID_OBJECT_ID;

/// A ray in 3D space
pub const Ray = struct {
    origin: [3]f32,
    direction: [3]f32, // Should be normalized
};

/// Convert screen coordinates to a world-space ray
/// screen_x, screen_y: Mouse position in screen pixels
/// screen_width, screen_height: Viewport size
/// inv_view_proj: Inverse of (projection * view) matrix
pub fn screenToRay(
    screen_x: f32,
    screen_y: f32,
    screen_width: f32,
    screen_height: f32,
    inv_view_proj: math.Mat4,
) Ray {
    // Convert to normalized device coordinates [-1, 1]
    const ndc_x = (2.0 * screen_x / screen_width) - 1.0;
    const ndc_y = 1.0 - (2.0 * screen_y / screen_height); // Flip Y

    // Near and far points in clip space (z = -1 for near, z = 1 for far in OpenGL)
    const near_clip = math.Vec4{ .elements = .{ ndc_x, ndc_y, -1.0, 1.0 } };
    const far_clip = math.Vec4{ .elements = .{ ndc_x, ndc_y, 1.0, 1.0 } };

    // Transform to world space
    const near_world = mat4MulVec4(inv_view_proj, near_clip);
    const far_world = mat4MulVec4(inv_view_proj, far_clip);

    // Perspective divide
    const near_pos: [3]f32 = .{
        near_world.elements[0] / near_world.elements[3],
        near_world.elements[1] / near_world.elements[3],
        near_world.elements[2] / near_world.elements[3],
    };
    const far_pos: [3]f32 = .{
        far_world.elements[0] / far_world.elements[3],
        far_world.elements[1] / far_world.elements[3],
        far_world.elements[2] / far_world.elements[3],
    };

    // Direction from near to far
    var direction: [3]f32 = .{
        far_pos[0] - near_pos[0],
        far_pos[1] - near_pos[1],
        far_pos[2] - near_pos[2],
    };

    // Normalize direction
    const len = math.bsqrt(direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2]);
    if (len > 0.0001) {
        direction[0] /= len;
        direction[1] /= len;
        direction[2] /= len;
    }

    return Ray{
        .origin = near_pos,
        .direction = direction,
    };
}

/// Test ray intersection with an axis-aligned bounding box
/// Returns distance along ray to intersection point, or null if no hit
pub fn rayIntersectsAABB(ray: Ray, min: [3]f32, max: [3]f32) ?f32 {
    // Slab intersection algorithm
    var t_min: f32 = -std.math.floatMax(f32);
    var t_max: f32 = std.math.floatMax(f32);

    for (0..3) |i| {
        if (@abs(ray.direction[i]) < 0.0001) {
            // Ray is parallel to slab
            if (ray.origin[i] < min[i] or ray.origin[i] > max[i]) {
                return null;
            }
        } else {
            const inv_d = 1.0 / ray.direction[i];
            var t1 = (min[i] - ray.origin[i]) * inv_d;
            var t2 = (max[i] - ray.origin[i]) * inv_d;

            if (t1 > t2) {
                const temp = t1;
                t1 = t2;
                t2 = temp;
            }

            t_min = @max(t_min, t1);
            t_max = @min(t_max, t2);

            if (t_min > t_max) {
                return null;
            }
        }
    }

    // Check if intersection is in front of ray
    if (t_max < 0) {
        return null;
    }

    // Return nearest intersection point
    return if (t_min >= 0) t_min else t_max;
}

/// Pick an object from the scene
/// Returns the ID of the closest hit object, or INVALID_OBJECT_ID if no hit
pub fn pickObject(scene: *EditorScene, ray: Ray) EditorObjectId {
    var closest_id: EditorObjectId = INVALID_OBJECT_ID;
    var closest_dist: f32 = std.math.floatMax(f32);

    for (scene.getAllObjects()) |obj| {
        if (!obj.is_visible) continue;

        if (rayIntersectsAABB(ray, obj.world_bounds_min, obj.world_bounds_max)) |dist| {
            if (dist < closest_dist) {
                closest_dist = dist;
                closest_id = obj.id;
            }
        }
    }

    return closest_id;
}

/// Matrix-vector multiplication helper
fn mat4MulVec4(m: math.Mat4, v: math.Vec4) math.Vec4 {
    // Column-major matrix multiplication
    const x = m.data[0] * v.elements[0] + m.data[4] * v.elements[1] + m.data[8] * v.elements[2] + m.data[12] * v.elements[3];
    const y = m.data[1] * v.elements[0] + m.data[5] * v.elements[1] + m.data[9] * v.elements[2] + m.data[13] * v.elements[3];
    const z = m.data[2] * v.elements[0] + m.data[6] * v.elements[1] + m.data[10] * v.elements[2] + m.data[14] * v.elements[3];
    const w = m.data[3] * v.elements[0] + m.data[7] * v.elements[1] + m.data[11] * v.elements[2] + m.data[15] * v.elements[3];

    return .{ .elements = .{ x, y, z, w } };
}
