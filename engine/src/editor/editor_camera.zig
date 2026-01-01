//! Editor Camera System
//! Fly camera following LearnOpenGL tutorial approach exactly.
//! https://learnopengl.com/Getting-started/Camera

const std = @import("std");
const math = @import("../math/math.zig");
const input = @import("../systems/input.zig");
const imgui = @import("../systems/imgui.zig");

/// Fly camera with WASD movement and mouse look (right-click to look)
pub const EditorCamera = struct {
    // Camera position in world space
    position: [3]f32 = .{ 0, 5, 10 },

    // Camera orientation vectors (computed from yaw/pitch)
    front: [3]f32 = .{ 0, 0, -1 }, // Direction camera is looking
    up: [3]f32 = .{ 0, 1, 0 }, // World up vector
    right: [3]f32 = .{ 1, 0, 0 }, // Right vector (computed)

    // Euler angles (in degrees, like LearnOpenGL)
    yaw: f32 = -90.0, // Yaw of -90 means looking along -Z axis
    pitch: f32 = 0.0,

    // Movement settings
    move_speed: f32 = 10.0,
    fast_move_multiplier: f32 = 3.0,
    look_sensitivity: f32 = 0.1,

    // Control state
    is_looking: bool = false,

    // Cached view matrix
    view_matrix: math.Mat4 = math.mat4Identity(),
    view_matrix_dirty: bool = true,

    const world_up: [3]f32 = .{ 0, 1, 0 };

    /// Update camera based on input
    pub fn update(self: *EditorCamera, delta_time: f32) void {
        // Skip if ImGui wants input
        if (imgui.ImGuiSystem.wantsCaptureMouse() or imgui.ImGuiSystem.wantsCaptureKeyboard()) {
            self.is_looking = false;
            return;
        }

        // Right-click for look mode
        const was_looking = self.is_looking;
        self.is_looking = input.isButtonDown(.right);

        // Mouse look (only while right-click held)
        if (self.is_looking and was_looking) {
            const mouse_delta = input.getMouseDelta();
            const xoffset = @as(f32, @floatCast(mouse_delta.x)) * self.look_sensitivity;
            const yoffset = @as(f32, @floatCast(-mouse_delta.y)) * self.look_sensitivity; // Reversed: moving mouse up should look up

            self.yaw += xoffset;
            self.pitch += yoffset;

            // Clamp pitch to avoid flipping
            if (self.pitch > 89.0) self.pitch = 89.0;
            if (self.pitch < -89.0) self.pitch = -89.0;

            // Update front vector from Euler angles
            self.updateVectors();
        }

        // WASD movement - only while right-click held (is_looking)
        if (self.is_looking) {
            const camera_speed = self.move_speed * delta_time * (if (input.isKeyDown(.left_shift)) self.fast_move_multiplier else 1.0);

            if (input.isKeyDown(.w)) {
                // Move forward (in direction camera is looking)
                self.position[0] += self.front[0] * camera_speed;
                self.position[1] += self.front[1] * camera_speed;
                self.position[2] += self.front[2] * camera_speed;
                self.view_matrix_dirty = true;
            }
            if (input.isKeyDown(.s)) {
                // Move backward
                self.position[0] -= self.front[0] * camera_speed;
                self.position[1] -= self.front[1] * camera_speed;
                self.position[2] -= self.front[2] * camera_speed;
                self.view_matrix_dirty = true;
            }
            if (input.isKeyDown(.a)) {
                // Strafe left
                self.position[0] -= self.right[0] * camera_speed;
                self.position[1] -= self.right[1] * camera_speed;
                self.position[2] -= self.right[2] * camera_speed;
                self.view_matrix_dirty = true;
            }
            if (input.isKeyDown(.d)) {
                // Strafe right
                self.position[0] += self.right[0] * camera_speed;
                self.position[1] += self.right[1] * camera_speed;
                self.position[2] += self.right[2] * camera_speed;
                self.view_matrix_dirty = true;
            }
            if (input.isKeyDown(.e)) {
                // Move up (world space)
                self.position[1] += camera_speed;
                self.view_matrix_dirty = true;
            }
            if (input.isKeyDown(.q)) {
                // Move down (world space)
                self.position[1] -= camera_speed;
                self.view_matrix_dirty = true;
            }
        }
    }

    /// Update front, right, and up vectors from Euler angles
    /// This is the core of the LearnOpenGL camera
    fn updateVectors(self: *EditorCamera) void {
        // Calculate front vector from Euler angles
        const yaw_rad = math.degToRad(self.yaw);
        const pitch_rad = math.degToRad(self.pitch);

        const cos_pitch = @cos(pitch_rad);
        const sin_pitch = @sin(pitch_rad);
        const cos_yaw = @cos(yaw_rad);
        const sin_yaw = @sin(yaw_rad);

        // LearnOpenGL formula:
        // front.x = cos(yaw) * cos(pitch)
        // front.y = sin(pitch)
        // front.z = sin(yaw) * cos(pitch)
        self.front[0] = cos_yaw * cos_pitch;
        self.front[1] = sin_pitch;
        self.front[2] = sin_yaw * cos_pitch;

        // Normalize front (should already be normalized, but be safe)
        const len = @sqrt(self.front[0] * self.front[0] + self.front[1] * self.front[1] + self.front[2] * self.front[2]);
        self.front[0] /= len;
        self.front[1] /= len;
        self.front[2] /= len;

        // Right = normalize(cross(front, world_up))
        // cross(a, b) = (a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x)
        self.right[0] = self.front[1] * world_up[2] - self.front[2] * world_up[1];
        self.right[1] = self.front[2] * world_up[0] - self.front[0] * world_up[2];
        self.right[2] = self.front[0] * world_up[1] - self.front[1] * world_up[0];
        const right_len = @sqrt(self.right[0] * self.right[0] + self.right[1] * self.right[1] + self.right[2] * self.right[2]);
        self.right[0] /= right_len;
        self.right[1] /= right_len;
        self.right[2] /= right_len;

        // Up = normalize(cross(right, front))
        self.up[0] = self.right[1] * self.front[2] - self.right[2] * self.front[1];
        self.up[1] = self.right[2] * self.front[0] - self.right[0] * self.front[2];
        self.up[2] = self.right[0] * self.front[1] - self.right[1] * self.front[0];
        const up_len = @sqrt(self.up[0] * self.up[0] + self.up[1] * self.up[1] + self.up[2] * self.up[2]);
        self.up[0] /= up_len;
        self.up[1] /= up_len;
        self.up[2] /= up_len;

        self.view_matrix_dirty = true;
    }

    /// Get the view matrix using lookAt
    pub fn getViewMatrix(self: *EditorCamera) math.Mat4 {
        if (self.view_matrix_dirty) {
            self.recalculateViewMatrix();
        }
        return self.view_matrix;
    }

    /// Recalculate view matrix using lookAt(position, position + front, up)
    fn recalculateViewMatrix(self: *EditorCamera) void {
        const pos = math.Vec3{ .elements = self.position };
        const target = math.Vec3{ .elements = .{
            self.position[0] + self.front[0],
            self.position[1] + self.front[1],
            self.position[2] + self.front[2],
        } };
        const up_vec = math.Vec3{ .elements = self.up };

        self.view_matrix = math.mat4LookAt(pos, target, up_vec);
        self.view_matrix_dirty = false;
    }

    /// Set camera position directly
    pub fn setPosition(self: *EditorCamera, pos: [3]f32) void {
        self.position = pos;
        self.view_matrix_dirty = true;
    }

    /// Set camera rotation directly (in degrees)
    pub fn setRotation(self: *EditorCamera, yaw_deg: f32, pitch_deg: f32) void {
        self.yaw = yaw_deg;
        self.pitch = std.math.clamp(pitch_deg, -89.0, 89.0);
        self.updateVectors();
    }

    /// Look at a target position
    pub fn lookAt(self: *EditorCamera, target: [3]f32) void {
        const dx = target[0] - self.position[0];
        const dy = target[1] - self.position[1];
        const dz = target[2] - self.position[2];

        const horizontal_dist = @sqrt(dx * dx + dz * dz);

        // Calculate yaw and pitch in degrees
        self.yaw = math.radToDeg(std.math.atan2(dz, dx));
        self.pitch = math.radToDeg(std.math.atan2(dy, horizontal_dist));
        self.pitch = std.math.clamp(self.pitch, -89.0, 89.0);

        self.updateVectors();
    }

    /// Get forward direction vector
    pub fn getForward(self: *const EditorCamera) [3]f32 {
        return self.front;
    }

    /// Get right direction vector
    pub fn getRight(self: *const EditorCamera) [3]f32 {
        return self.right;
    }
};
