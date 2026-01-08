//! Shadow mapping system for directional and point lights.
//!
//! Manages cascade shadow maps for directional lights and cubemap shadows for point lights.

const std = @import("std");
const vk_context = @import("vulkan/context.zig");
const vk = vk_context.vk;
const logger = @import("../core/logging.zig");
const math = @import("../math/math.zig");
const math_types = @import("../math/types.zig");
const light = @import("../systems/light.zig");

/// Number of cascade splits for directional light shadows
pub const CASCADE_COUNT: u32 = 4;

/// Shadow map resolution for each cascade
pub const CASCADE_RESOLUTION: u32 = 2048;

/// Point light shadow map resolution (per cubemap face)
pub const POINT_SHADOW_RESOLUTION: u32 = 1024;

/// Maximum number of shadowing point lights
pub const MAX_POINT_SHADOWS: u32 = 4;

/// Cascade shadow map data for a single cascade
pub const CascadeShadowMap = struct {
    /// Depth texture (2D)
    image: vk.VkImage = null,
    memory: vk.VkDeviceMemory = null,
    view: vk.VkImageView = null,

    /// Framebuffer for rendering
    framebuffer: vk.VkFramebuffer = null,

    /// Light-space view-projection matrix
    view_proj_matrix: math_types.Mat4,

    /// Far plane distance for this cascade
    split_depth: f32,
};

/// Point light shadow map (cubemap)
pub const PointShadowMap = struct {
    /// Depth cubemap texture
    image: vk.VkImage = null,
    memory: vk.VkDeviceMemory = null,
    view: vk.VkImageView = null,

    /// Face views (6 faces: +X, -X, +Y, -Y, +Z, -Z)
    face_views: [6]vk.VkImageView = [_]vk.VkImageView{null} ** 6,

    /// Framebuffers (one per face)
    framebuffers: [6]vk.VkFramebuffer = [_]vk.VkFramebuffer{null} ** 6,

    /// View-projection matrices for each face
    view_proj_matrices: [6]math_types.Mat4,

    /// Light index this shadow map is associated with
    light_index: u32 = 0,
};

/// Main shadow system state
pub const ShadowSystem = struct {
    /// Cascade shadow maps for directional light
    cascades: [CASCADE_COUNT]CascadeShadowMap,

    /// Point light shadow maps
    point_shadows: [MAX_POINT_SHADOWS]PointShadowMap,

    /// Shadow render pass
    shadow_renderpass: vk.VkRenderPass = null,

    /// Sampler for shadow maps
    shadow_sampler: vk.VkSampler = null,

    /// Descriptor sets for shadow maps (Set 2)
    shadow_descriptor_layout: vk.VkDescriptorSetLayout = null,
    shadow_descriptor_pool: vk.VkDescriptorPool = null,
    shadow_descriptor_set: vk.VkDescriptorSet = null,

    /// Shadow pipeline (for depth rendering)
    shadow_pipeline: vk.VkPipeline = null,
    shadow_pipeline_layout: vk.VkPipelineLayout = null,

    /// Cascade split distances (in view space)
    cascade_splits: [CASCADE_COUNT]f32 = [_]f32{0.0} ** CASCADE_COUNT,

    /// Shadow parameters
    shadow_bias: f32 = 0.005,
    slope_bias: f32 = 0.01,
    pcf_samples: u32 = 16, // 4x4 PCF

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ShadowSystem {
        return ShadowSystem{
            .cascades = undefined,
            .point_shadows = undefined,
            .allocator = allocator,
        };
    }

    /// Calculate cascade split distances using logarithmic scheme
    pub fn calculateCascadeSplits(near: f32, far: f32, lambda: f32) [CASCADE_COUNT]f32 {
        var splits: [CASCADE_COUNT]f32 = undefined;

        const range = far - near;
        const ratio = far / near;

        for (0..CASCADE_COUNT) |i| {
            const p = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(CASCADE_COUNT));

            // Logarithmic split
            const log_split = near * std.math.pow(f32, ratio, p);

            // Linear split
            const linear_split = near + range * p;

            // Blend between logarithmic and linear
            splits[i] = lambda * log_split + (1.0 - lambda) * linear_split;
        }

        return splits;
    }

    /// Calculate light-space matrices for cascade shadow maps
    pub fn calculateCascadeMatrices(
        camera_pos: [3]f32,
        camera_view: math_types.Mat4,
        camera_proj: math_types.Mat4,
        light_dir: [3]f32,
        near: f32,
        far: f32,
    ) [CASCADE_COUNT]math_types.Mat4 {
        var matrices: [CASCADE_COUNT]math_types.Mat4 = undefined;
        const splits = calculateCascadeSplits(near, far, 0.95); // lambda = 0.95

        var last_split = near;

        for (0..CASCADE_COUNT) |i| {
            const split_near = last_split;
            const split_far = splits[i];

            // Calculate frustum corners for this cascade
            const inv_view_proj = math.mat4Inverse(math.mat4Mul(camera_proj, camera_view));

            // Get frustum corners in world space
            var frustum_corners: [8][3]f32 = undefined;
            var corner_idx: usize = 0;

            for (0..2) |x| {
                for (0..2) |y| {
                    for (0..2) |z| {
                        const ndc = [4]f32{
                            if (x == 0) -1.0 else 1.0,
                            if (y == 0) -1.0 else 1.0,
                            if (z == 0) split_near else split_far,
                            1.0,
                        };

                        // Transform to world space
                        var world_pos = math.mat4MulVec4(inv_view_proj, ndc);

                        // Perspective divide
                        const w_inv = 1.0 / world_pos[3];
                        frustum_corners[corner_idx] = [3]f32{
                            world_pos[0] * w_inv,
                            world_pos[1] * w_inv,
                            world_pos[2] * w_inv,
                        };
                        corner_idx += 1;
                    }
                }
            }

            // Calculate frustum center
            var center = [3]f32{ 0, 0, 0 };
            for (frustum_corners) |corner| {
                center[0] += corner[0];
                center[1] += corner[1];
                center[2] += corner[2];
            }
            center[0] /= 8.0;
            center[1] /= 8.0;
            center[2] /= 8.0;

            // Create light view matrix (look at frustum center from light direction)
            const light_view = createLightViewMatrix(center, light_dir);

            // Calculate orthographic bounds in light space
            var min_x: f32 = std.math.floatMax(f32);
            var max_x: f32 = -std.math.floatMax(f32);
            var min_y: f32 = std.math.floatMax(f32);
            var max_y: f32 = -std.math.floatMax(f32);
            var min_z: f32 = std.math.floatMax(f32);
            var max_z: f32 = -std.math.floatMax(f32);

            for (frustum_corners) |corner| {
                const light_space = math.mat4MulVec4(light_view, [4]f32{ corner[0], corner[1], corner[2], 1.0 });

                min_x = @min(min_x, light_space[0]);
                max_x = @max(max_x, light_space[0]);
                min_y = @min(min_y, light_space[1]);
                max_y = @max(max_y, light_space[1]);
                min_z = @min(min_z, light_space[2]);
                max_z = @max(max_z, light_space[2]);
            }

            // Extend Z bounds to include shadow casters behind the frustum
            const z_mult: f32 = 10.0;
            if (min_z < 0) {
                min_z *= z_mult;
            } else {
                min_z /= z_mult;
            }
            if (max_z < 0) {
                max_z /= z_mult;
            } else {
                max_z *= z_mult;
            }

            // Create orthographic projection
            const light_proj = math.mat4Orthographic(min_x, max_x, min_y, max_y, min_z, max_z);

            matrices[i] = math.mat4Mul(light_proj, light_view);
            last_split = split_far;
        }

        return matrices;
    }

    /// Create a light view matrix looking from light direction at a target point
    fn createLightViewMatrix(target: [3]f32, light_dir: [3]f32) math_types.Mat4 {
        // Position light far away in the opposite direction of light_dir
        const distance: f32 = 100.0;
        const light_pos = [3]f32{
            target[0] - light_dir[0] * distance,
            target[1] - light_dir[1] * distance,
            target[2] - light_dir[2] * distance,
        };

        // Create look-at matrix
        return math.mat4LookAt(light_pos, target, [3]f32{ 0, 1, 0 });
    }

    /// Calculate view-projection matrices for a point light's cubemap faces
    /// Returns 6 matrices for: +X, -X, +Y, -Y, +Z, -Z faces
    pub fn calculatePointLightMatrices(light_pos: [3]f32, near: f32, far: f32) [6]math_types.Mat4 {
        var matrices: [6]math_types.Mat4 = undefined;

        // Perspective projection for 90 degree FOV (covers cubemap face)
        const proj = math.mat4Perspective(math.degToRad(90.0), 1.0, near, far);

        // Target and up vectors for each cubemap face
        const directions = [6][2][3]f32{
            // +X face (right)
            .{ .{ 1, 0, 0 }, .{ 0, -1, 0 } }, // target, up
            // -X face (left)
            .{ .{ -1, 0, 0 }, .{ 0, -1, 0 } },
            // +Y face (up)
            .{ .{ 0, 1, 0 }, .{ 0, 0, 1 } },
            // -Y face (down)
            .{ .{ 0, -1, 0 }, .{ 0, 0, -1 } },
            // +Z face (forward)
            .{ .{ 0, 0, 1 }, .{ 0, -1, 0 } },
            // -Z face (back)
            .{ .{ 0, 0, -1 }, .{ 0, -1, 0 } },
        };

        for (0..6) |i| {
            const target = [3]f32{
                light_pos[0] + directions[i][0][0],
                light_pos[1] + directions[i][0][1],
                light_pos[2] + directions[i][0][2],
            };
            const up = directions[i][1];

            const view = math.mat4LookAt(light_pos, target, up);
            matrices[i] = math.mat4Mul(proj, view);
        }

        return matrices;
    }
};
