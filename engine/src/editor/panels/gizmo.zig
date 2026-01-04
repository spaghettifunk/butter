//! Gizmo System
//! Provides transform manipulation gizmo for objects in the scene.

const std = @import("std");
const imgui = @import("../../systems/imgui.zig");
const input = @import("../../systems/input.zig");
const math = @import("../../math/math.zig");

const c = imgui.c;

/// Gizmo manipulation mode.
pub const GizmoMode = enum {
    translate,
    rotate,
    scale,
};

/// Coordinate space for gizmo operations.
pub const GizmoSpace = enum {
    local,
    world,
};

/// Axis for gizmo manipulation.
pub const Axis = enum {
    none,
    x,
    y,
    z,
    xy,
    xz,
    yz,
    all,
};

/// Transform delta from gizmo manipulation.
pub const TransformDelta = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    rotation: [3]f32 = .{ 0, 0, 0 }, // Euler angles in degrees
    scale: [3]f32 = .{ 1, 1, 1 },
};

pub const Gizmo = struct {
    /// Current manipulation mode.
    mode: GizmoMode = .translate,

    /// Current coordinate space.
    space: GizmoSpace = .world,

    /// Whether the gizmo is visible.
    is_visible: bool = false,

    /// Whether the gizmo is currently being dragged.
    is_active: bool = false,

    /// Target position.
    position: [3]f32 = .{ 0, 0, 0 },

    /// Target rotation (Euler angles in degrees).
    rotation: [3]f32 = .{ 0, 0, 0 },

    /// Target scale.
    scale: [3]f32 = .{ 1, 1, 1 },

    /// Currently hovered axis.
    hovered_axis: Axis = .none,

    /// Currently dragging axis.
    dragging_axis: Axis = .none,

    /// Drag start position (screen space).
    drag_start: [2]f32 = .{ 0, 0 },

    /// View-projection matrix for world-to-screen projection
    view_proj: math.Mat4 = math.mat4Identity(),

    /// Screen dimensions for projection
    screen_width: f32 = 1920,
    screen_height: f32 = 1080,

    /// Whether to use world position or screen center
    use_world_position: bool = false,

    /// Cached screen position of gizmo
    screen_pos: [2]f32 = .{ 0, 0 },

    /// Cached projected axis directions (screen-space, normalized)
    projected_x_dir: [2]f32 = .{ 1, 0 },
    projected_y_dir: [2]f32 = .{ 0, -1 },
    projected_z_dir: [2]f32 = .{ 0.7, 0.7 },

    /// Set the gizmo mode.
    pub fn setMode(self: *Gizmo, mode: GizmoMode) void {
        self.mode = mode;
    }

    /// Toggle between local and world space.
    pub fn toggleSpace(self: *Gizmo) void {
        self.space = if (self.space == .local) .world else .local;
    }

    /// Set the target transform.
    pub fn setTarget(self: *Gizmo, pos: [3]f32, rot: [3]f32, scl: [3]f32) void {
        self.position = pos;
        self.rotation = rot;
        self.scale = scl;
    }

    /// Set the view-projection matrix for world-to-screen projection
    pub fn setViewProjection(self: *Gizmo, view_proj_matrix: math.Mat4, width: f32, height: f32) void {
        self.view_proj = view_proj_matrix;
        self.screen_width = width;
        self.screen_height = height;
        self.use_world_position = true;
    }

    /// Project a world position to screen coordinates
    /// Returns null if the position is behind the camera
    fn worldToScreen(self: *Gizmo, world_pos: [3]f32) ?[2]f32 {
        // Transform to clip space
        const x = self.view_proj.data[0] * world_pos[0] + self.view_proj.data[4] * world_pos[1] + self.view_proj.data[8] * world_pos[2] + self.view_proj.data[12];
        const y = self.view_proj.data[1] * world_pos[0] + self.view_proj.data[5] * world_pos[1] + self.view_proj.data[9] * world_pos[2] + self.view_proj.data[13];
        const w = self.view_proj.data[3] * world_pos[0] + self.view_proj.data[7] * world_pos[1] + self.view_proj.data[11] * world_pos[2] + self.view_proj.data[15];

        // Behind camera check
        if (w <= 0.001) return null;

        // Perspective divide to NDC
        const ndc_x = x / w;
        const ndc_y = y / w;

        // Convert to screen coordinates
        const screen_x = (ndc_x + 1.0) * 0.5 * self.screen_width;
        const screen_y = (1.0 - ndc_y) * 0.5 * self.screen_height; // Flip Y

        return .{ screen_x, screen_y };
    }

    /// Project a world-space axis direction to screen space
    fn projectWorldAxis(self: *Gizmo, origin: [3]f32, axis_dir: [3]f32, length_pixels: f32) struct {
        screen_start: [2]f32,
        screen_end: [2]f32,
        direction: [2]f32,
        is_visible: bool,
    } {
        const screen_start = self.worldToScreen(origin) orelse return .{
            .screen_start = .{ 0, 0 },
            .screen_end = .{ 0, 0 },
            .direction = .{ 0, 0 },
            .is_visible = false,
        };

        // Calculate world-space endpoint
        const world_end = [3]f32{
            origin[0] + axis_dir[0],
            origin[1] + axis_dir[1],
            origin[2] + axis_dir[2],
        };

        const screen_end_proj = self.worldToScreen(world_end) orelse return .{
            .screen_start = screen_start,
            .screen_end = screen_start,
            .direction = .{ 1, 0 },
            .is_visible = false,
        };

        // Calculate screen-space direction
        const dx = screen_end_proj[0] - screen_start[0];
        const dy = screen_end_proj[1] - screen_start[1];
        const len = @sqrt(dx * dx + dy * dy);

        var direction = [2]f32{ 1, 0 };
        if (len > 0.001) {
            direction = .{ dx / len, dy / len };
        }

        // Scale to desired pixel length
        const screen_end = [2]f32{
            screen_start[0] + direction[0] * length_pixels,
            screen_start[1] + direction[1] * length_pixels,
        };

        return .{
            .screen_start = screen_start,
            .screen_end = screen_end,
            .direction = direction,
            .is_visible = true,
        };
    }

    /// Render the gizmo overlay.
    /// Returns a transform delta if manipulation occurred.
    pub fn render(self: *Gizmo) ?TransformDelta {
        if (!self.is_visible) return null;

        const draw_list = imgui.getForegroundDrawList();

        const io = imgui.getIO();
        const display_size = io.*.DisplaySize;

        // Calculate gizmo screen position
        var center_x: f32 = undefined;
        var center_y: f32 = undefined;

        if (self.use_world_position) {
            // Project world position to screen
            if (self.worldToScreen(self.position)) |screen_pos| {
                center_x = screen_pos[0];
                center_y = screen_pos[1];
                self.screen_pos = screen_pos;
            } else {
                // Position is behind camera, don't render
                return null;
            }
        } else {
            // Fallback to screen center
            center_x = display_size.x / 2;
            center_y = display_size.y / 2;
        }

        // Gizmo size
        const axis_length: f32 = 100;
        const axis_thickness: f32 = 3;
        const arrow_size: f32 = 12;

        // Project world-space axes to screen space
        const x_axis = self.projectWorldAxis(self.position, .{ 1, 0, 0 }, axis_length);
        const y_axis = self.projectWorldAxis(self.position, .{ 0, 1, 0 }, axis_length);
        const z_axis = self.projectWorldAxis(self.position, .{ 0, 0, 1 }, axis_length);

        // Cache projected directions for drag calculations
        self.projected_x_dir = x_axis.direction;
        self.projected_y_dir = y_axis.direction;
        self.projected_z_dir = z_axis.direction;

        // Colors (ABGR format)
        const x_color: u32 = 0xFF0000FF; // Red
        const y_color: u32 = 0xFF00FF00; // Green
        const z_color: u32 = 0xFFFF0000; // Blue
        const hover_color: u32 = 0xFF00FFFF; // Yellow
        const text_color: u32 = 0xFFFFFFFF; // White
        const bg_color: u32 = 0xCC1A1A1A; // Semi-transparent dark

        // Check for hover
        const mouse_pos = input.getMousePosition();
        const mx = @as(f32, @floatCast(mouse_pos.x));
        const my = @as(f32, @floatCast(mouse_pos.y));

        self.hovered_axis = self.checkAxisHoverProjected(mx, my, x_axis, y_axis, z_axis, axis_length);

        // Handle dragging
        var delta: ?TransformDelta = null;
        if (input.isButtonDown(.left)) {
            if (!self.is_active and self.hovered_axis != .none) {
                // Start dragging
                self.is_active = true;
                self.dragging_axis = self.hovered_axis;
                self.drag_start = .{ mx, my };
            } else if (self.is_active) {
                // Continue dragging
                const dx = mx - self.drag_start[0];
                const dy = my - self.drag_start[1];
                delta = self.calculateDelta(dx, dy);
                self.drag_start = .{ mx, my };
            }
        } else {
            self.is_active = false;
            self.dragging_axis = .none;
        }

        // Draw axes based on mode
        switch (self.mode) {
            .translate => {
                // X axis
                if (x_axis.is_visible) {
                    const x_col = if (self.hovered_axis == .x or self.dragging_axis == .x) hover_color else x_color;
                    imgui.drawListAddLineEx(
                        draw_list,
                        .{ .x = x_axis.screen_start[0], .y = x_axis.screen_start[1] },
                        .{ .x = x_axis.screen_end[0], .y = x_axis.screen_end[1] },
                        x_col,
                        axis_thickness,
                    );
                    // Arrow head
                    const perp_x = -x_axis.direction[1] * arrow_size / 2;
                    const perp_y = x_axis.direction[0] * arrow_size / 2;
                    imgui.drawListAddTriangleFilled(
                        draw_list,
                        .{ .x = x_axis.screen_end[0] + x_axis.direction[0] * arrow_size, .y = x_axis.screen_end[1] + x_axis.direction[1] * arrow_size },
                        .{ .x = x_axis.screen_end[0] + perp_x, .y = x_axis.screen_end[1] + perp_y },
                        .{ .x = x_axis.screen_end[0] - perp_x, .y = x_axis.screen_end[1] - perp_y },
                        x_col,
                    );
                    imgui.drawListAddText(draw_list, .{ .x = x_axis.screen_end[0] + x_axis.direction[0] * (arrow_size + 5), .y = x_axis.screen_end[1] + x_axis.direction[1] * (arrow_size + 5) - 7 }, x_col, "X");
                }

                // Y axis
                if (y_axis.is_visible) {
                    const y_col = if (self.hovered_axis == .y or self.dragging_axis == .y) hover_color else y_color;
                    imgui.drawListAddLineEx(
                        draw_list,
                        .{ .x = y_axis.screen_start[0], .y = y_axis.screen_start[1] },
                        .{ .x = y_axis.screen_end[0], .y = y_axis.screen_end[1] },
                        y_col,
                        axis_thickness,
                    );
                    // Arrow head
                    const perp_x = -y_axis.direction[1] * arrow_size / 2;
                    const perp_y = y_axis.direction[0] * arrow_size / 2;
                    imgui.drawListAddTriangleFilled(
                        draw_list,
                        .{ .x = y_axis.screen_end[0] + y_axis.direction[0] * arrow_size, .y = y_axis.screen_end[1] + y_axis.direction[1] * arrow_size },
                        .{ .x = y_axis.screen_end[0] + perp_x, .y = y_axis.screen_end[1] + perp_y },
                        .{ .x = y_axis.screen_end[0] - perp_x, .y = y_axis.screen_end[1] - perp_y },
                        y_col,
                    );
                    imgui.drawListAddText(draw_list, .{ .x = y_axis.screen_end[0] + y_axis.direction[0] * (arrow_size + 5), .y = y_axis.screen_end[1] + y_axis.direction[1] * (arrow_size + 5) - 7 }, y_col, "Y");
                }

                // Z axis
                if (z_axis.is_visible) {
                    const z_col = if (self.hovered_axis == .z or self.dragging_axis == .z) hover_color else z_color;
                    imgui.drawListAddLineEx(
                        draw_list,
                        .{ .x = z_axis.screen_start[0], .y = z_axis.screen_start[1] },
                        .{ .x = z_axis.screen_end[0], .y = z_axis.screen_end[1] },
                        z_col,
                        axis_thickness,
                    );
                    // Arrow head
                    const perp_x = -z_axis.direction[1] * arrow_size / 2;
                    const perp_y = z_axis.direction[0] * arrow_size / 2;
                    imgui.drawListAddTriangleFilled(
                        draw_list,
                        .{ .x = z_axis.screen_end[0] + z_axis.direction[0] * arrow_size, .y = z_axis.screen_end[1] + z_axis.direction[1] * arrow_size },
                        .{ .x = z_axis.screen_end[0] + perp_x, .y = z_axis.screen_end[1] + perp_y },
                        .{ .x = z_axis.screen_end[0] - perp_x, .y = z_axis.screen_end[1] - perp_y },
                        z_col,
                    );
                    imgui.drawListAddText(draw_list, .{ .x = z_axis.screen_end[0] + z_axis.direction[0] * (arrow_size + 5), .y = z_axis.screen_end[1] + z_axis.direction[1] * (arrow_size + 5) - 7 }, z_col, "Z");
                }
            },
            .rotate => {
                // Draw rotation circles representing each rotation plane
                const radius: f32 = axis_length * 0.8;
                const num_segments: i32 = 48;

                // For rotation gizmos, we draw circles in 3D space projected to screen
                // X rotation: circle in YZ plane (perpendicular to X axis)
                const x_col = if (self.hovered_axis == .x or self.dragging_axis == .x) hover_color else x_color;
                self.drawRotationCircle(draw_list, .{ 1, 0, 0 }, radius, x_col, axis_thickness, num_segments);

                // Y rotation: circle in XZ plane (perpendicular to Y axis)
                const y_col = if (self.hovered_axis == .y or self.dragging_axis == .y) hover_color else y_color;
                self.drawRotationCircle(draw_list, .{ 0, 1, 0 }, radius, y_col, axis_thickness, num_segments);

                // Z rotation: circle in XY plane (perpendicular to Z axis)
                const z_col = if (self.hovered_axis == .z or self.dragging_axis == .z) hover_color else z_color;
                self.drawRotationCircle(draw_list, .{ 0, 0, 1 }, radius, z_col, axis_thickness, num_segments);

                // Draw labels at the end of each axis
                if (x_axis.is_visible) {
                    imgui.drawListAddText(draw_list, .{ .x = x_axis.screen_end[0] + 5, .y = x_axis.screen_end[1] - 7 }, x_col, "X");
                }
                if (y_axis.is_visible) {
                    imgui.drawListAddText(draw_list, .{ .x = y_axis.screen_end[0] + 5, .y = y_axis.screen_end[1] - 7 }, y_col, "Y");
                }
                if (z_axis.is_visible) {
                    imgui.drawListAddText(draw_list, .{ .x = z_axis.screen_end[0] + 5, .y = z_axis.screen_end[1] - 7 }, z_col, "Z");
                }
            },
            .scale => {
                const box_size: f32 = 5;

                // X axis with box
                if (x_axis.is_visible) {
                    const x_col = if (self.hovered_axis == .x or self.dragging_axis == .x) hover_color else x_color;
                    imgui.drawListAddLineEx(
                        draw_list,
                        .{ .x = x_axis.screen_start[0], .y = x_axis.screen_start[1] },
                        .{ .x = x_axis.screen_end[0], .y = x_axis.screen_end[1] },
                        x_col,
                        axis_thickness,
                    );
                    // Box at end
                    imgui.drawListAddRectFilled(
                        draw_list,
                        .{ .x = x_axis.screen_end[0] - box_size, .y = x_axis.screen_end[1] - box_size },
                        .{ .x = x_axis.screen_end[0] + box_size, .y = x_axis.screen_end[1] + box_size },
                        x_col,
                    );
                    imgui.drawListAddText(draw_list, .{ .x = x_axis.screen_end[0] + x_axis.direction[0] * 10, .y = x_axis.screen_end[1] + x_axis.direction[1] * 10 - 7 }, x_col, "X");
                }

                // Y axis with box
                if (y_axis.is_visible) {
                    const y_col = if (self.hovered_axis == .y or self.dragging_axis == .y) hover_color else y_color;
                    imgui.drawListAddLineEx(
                        draw_list,
                        .{ .x = y_axis.screen_start[0], .y = y_axis.screen_start[1] },
                        .{ .x = y_axis.screen_end[0], .y = y_axis.screen_end[1] },
                        y_col,
                        axis_thickness,
                    );
                    // Box at end
                    imgui.drawListAddRectFilled(
                        draw_list,
                        .{ .x = y_axis.screen_end[0] - box_size, .y = y_axis.screen_end[1] - box_size },
                        .{ .x = y_axis.screen_end[0] + box_size, .y = y_axis.screen_end[1] + box_size },
                        y_col,
                    );
                    imgui.drawListAddText(draw_list, .{ .x = y_axis.screen_end[0] + y_axis.direction[0] * 10, .y = y_axis.screen_end[1] + y_axis.direction[1] * 10 - 7 }, y_col, "Y");
                }

                // Z axis with box
                if (z_axis.is_visible) {
                    const z_col = if (self.hovered_axis == .z or self.dragging_axis == .z) hover_color else z_color;
                    imgui.drawListAddLineEx(
                        draw_list,
                        .{ .x = z_axis.screen_start[0], .y = z_axis.screen_start[1] },
                        .{ .x = z_axis.screen_end[0], .y = z_axis.screen_end[1] },
                        z_col,
                        axis_thickness,
                    );
                    // Box at end
                    imgui.drawListAddRectFilled(
                        draw_list,
                        .{ .x = z_axis.screen_end[0] - box_size, .y = z_axis.screen_end[1] - box_size },
                        .{ .x = z_axis.screen_end[0] + box_size, .y = z_axis.screen_end[1] + box_size },
                        z_col,
                    );
                    imgui.drawListAddText(draw_list, .{ .x = z_axis.screen_end[0] + z_axis.direction[0] * 10, .y = z_axis.screen_end[1] + z_axis.direction[1] * 10 - 7 }, z_col, "Z");
                }

                // Center cube for uniform scale
                const cx = x_axis.screen_start[0];
                const cy = x_axis.screen_start[1];
                const all_col = if (self.hovered_axis == .all or self.dragging_axis == .all) hover_color else text_color;
                imgui.drawListAddRectFilled(
                    draw_list,
                    .{ .x = cx - 8, .y = cy - 8 },
                    .{ .x = cx + 8, .y = cy + 8 },
                    all_col,
                );
            },
        }

        // Draw mode/space indicator
        const mode_str: [*:0]const u8 = switch (self.mode) {
            .translate => "Translate (T)",
            .rotate => "Rotate (R)",
            .scale => "Scale (S)",
        };
        const space_str: [*:0]const u8 = if (self.space == .local) "Local (X)" else "World (X)";

        // Info panel background
        const info_x: f32 = 10;
        const info_y = display_size.y - 60;
        imgui.drawListAddRectFilledEx(
            draw_list,
            .{ .x = info_x, .y = info_y },
            .{ .x = info_x + 150, .y = info_y + 50 },
            bg_color,
            5.0,
            0,
        );

        imgui.drawListAddText(draw_list, .{ .x = info_x + 8, .y = info_y + 8 }, text_color, mode_str);
        imgui.drawListAddText(draw_list, .{ .x = info_x + 8, .y = info_y + 28 }, text_color, space_str);

        return delta;
    }

    /// Check which axis is being hovered using projected axes.
    fn checkAxisHoverProjected(
        self: *Gizmo,
        mx: f32,
        my: f32,
        x_axis: anytype,
        y_axis: anytype,
        z_axis: anytype,
        length: f32,
    ) Axis {
        const threshold: f32 = 15;

        if (self.mode == .rotate) {
            // For rotation mode, fall back to old circular detection (needs improvement later)
            const cx = x_axis.screen_start[0];
            const cy = x_axis.screen_start[1];
            return self.checkAxisHover(mx, my, cx, cy, length);
        }

        // Translate / Scale: Check distance to projected lines
        // Check X axis
        if (x_axis.is_visible) {
            const dist = pointToLineDistance(
                mx,
                my,
                x_axis.screen_start[0],
                x_axis.screen_start[1],
                x_axis.screen_end[0],
                x_axis.screen_end[1],
            );
            if (dist < threshold) return .x;
        }

        // Check Y axis
        if (y_axis.is_visible) {
            const dist = pointToLineDistance(
                mx,
                my,
                y_axis.screen_start[0],
                y_axis.screen_start[1],
                y_axis.screen_end[0],
                y_axis.screen_end[1],
            );
            if (dist < threshold) return .y;
        }

        // Check Z axis
        if (z_axis.is_visible) {
            const dist = pointToLineDistance(
                mx,
                my,
                z_axis.screen_start[0],
                z_axis.screen_start[1],
                z_axis.screen_end[0],
                z_axis.screen_end[1],
            );
            if (dist < threshold) return .z;
        }

        // Check center (for uniform scale)
        const cx = x_axis.screen_start[0];
        const cy = x_axis.screen_start[1];
        if (mx >= cx - 10 and mx <= cx + 10 and my >= cy - 10 and my <= cy + 10) {
            return .all;
        }

        return .none;
    }

    /// Check which axis is being hovered (old method for rotate mode).
    fn checkAxisHover(self: *Gizmo, mx: f32, my: f32, cx: f32, cy: f32, length: f32) Axis {
        const threshold: f32 = 15;

        if (self.mode == .rotate) {
            const radius = length * 0.8;
            const dx = mx - cx;
            const dy = my - cy;

            // Check Z axis (Tall Ellipse: rx=r*0.3, ry=r) - High priority (inner)
            {
                const rx = radius * 0.3;
                const ry = radius;
                const d = @sqrt((dx * dx) / (rx * rx) + (dy * dy) / (ry * ry));
                // Approximate pixel distance check: normalized dist * min_radius
                if (@abs(d - 1.0) * rx < threshold) return .z;
            }

            // Check Y axis (Wide Ellipse: rx=r, ry=r*0.3)
            {
                const rx = radius;
                const ry = radius * 0.3;
                const d = @sqrt((dx * dx) / (rx * rx) + (dy * dy) / (ry * ry));
                if (@abs(d - 1.0) * ry < threshold) return .y;
            }

            // Check X axis (Circle: r=radius) - Lowest priority (outer)
            {
                const dist = @sqrt(dx * dx + dy * dy);
                if (@abs(dist - radius) < threshold) return .x;
            }

            return .none;
        }

        // Translate / Scale logic
        // Check X axis
        if (my >= cy - threshold and my <= cy + threshold and mx >= cx and mx <= cx + length + threshold) {
            return .x;
        }

        // Check Y axis
        if (mx >= cx - threshold and mx <= cx + threshold and my >= cy - length - threshold and my <= cy) {
            return .y;
        }

        // Check Z axis (diagonal)
        const z_end_x = cx + length * 0.7;
        const z_end_y = cy + length * 0.7;
        const dist_to_z = pointToLineDistance(mx, my, cx, cy, z_end_x, z_end_y);
        if (dist_to_z < threshold and mx >= cx and my >= cy and mx <= z_end_x + threshold and my <= z_end_y + threshold) {
            return .z;
        }

        // Check center (for uniform scale)
        if (mx >= cx - 10 and mx <= cx + 10 and my >= cy - 10 and my <= cy + 10) {
            return .all;
        }

        return .none;
    }

    /// Calculate transform delta from mouse movement.
    fn calculateDelta(self: *Gizmo, dx: f32, dy: f32) TransformDelta {
        var delta = TransformDelta{};
        const sensitivity: f32 = 0.01;

        switch (self.mode) {
            .translate => {
                // Project mouse movement onto the screen-space axis direction
                switch (self.dragging_axis) {
                    .x => {
                        const proj = dx * self.projected_x_dir[0] + dy * self.projected_x_dir[1];
                        delta.position[0] = proj * sensitivity;
                    },
                    .y => {
                        const proj = dx * self.projected_y_dir[0] + dy * self.projected_y_dir[1];
                        delta.position[1] = proj * sensitivity;
                    },
                    .z => {
                        const proj = dx * self.projected_z_dir[0] + dy * self.projected_z_dir[1];
                        delta.position[2] = proj * sensitivity;
                    },
                    else => {},
                }
            },
            .rotate => {
                const rot_sensitivity: f32 = 0.5;
                switch (self.dragging_axis) {
                    .x => delta.rotation[0] = dy * rot_sensitivity,
                    .y => delta.rotation[1] = dx * rot_sensitivity,
                    .z => delta.rotation[2] = dx * rot_sensitivity,
                    else => {},
                }
            },
            .scale => {
                const scale_sensitivity: f32 = 0.01;
                switch (self.dragging_axis) {
                    .x => {
                        const proj = dx * self.projected_x_dir[0] + dy * self.projected_x_dir[1];
                        delta.scale[0] = 1.0 + proj * scale_sensitivity;
                    },
                    .y => {
                        const proj = dx * self.projected_y_dir[0] + dy * self.projected_y_dir[1];
                        delta.scale[1] = 1.0 + proj * scale_sensitivity;
                    },
                    .z => {
                        const proj = dx * self.projected_z_dir[0] + dy * self.projected_z_dir[1];
                        delta.scale[2] = 1.0 + proj * scale_sensitivity;
                    },
                    .all => {
                        const uniform = 1.0 + (dx - dy) * 0.5 * scale_sensitivity;
                        delta.scale = .{ uniform, uniform, uniform };
                    },
                    else => {},
                }
            },
        }

        return delta;
    }

    /// Draw a rotation circle in 3D space (perpendicular to the given axis)
    fn drawRotationCircle(
        self: *Gizmo,
        draw_list: *c.ImDrawList,
        axis_normal: [3]f32,
        radius: f32,
        color: u32,
        thickness: f32,
        num_segments: i32,
    ) void {
        // Generate circle points in 3D space perpendicular to the axis
        // We need two perpendicular vectors to the axis to define the plane
        var tangent1: [3]f32 = undefined;
        var tangent2: [3]f32 = undefined;

        // Find two perpendicular vectors to axis_normal
        if (@abs(axis_normal[0]) < 0.9) {
            tangent1 = .{ 1, 0, 0 };
        } else {
            tangent1 = .{ 0, 1, 0 };
        }

        // Cross product: tangent1 = axis_normal × tangent1
        const cross1 = [3]f32{
            axis_normal[1] * tangent1[2] - axis_normal[2] * tangent1[1],
            axis_normal[2] * tangent1[0] - axis_normal[0] * tangent1[2],
            axis_normal[0] * tangent1[1] - axis_normal[1] * tangent1[0],
        };
        const len1 = @sqrt(cross1[0] * cross1[0] + cross1[1] * cross1[1] + cross1[2] * cross1[2]);
        tangent1 = .{ cross1[0] / len1, cross1[1] / len1, cross1[2] / len1 };

        // Cross product: tangent2 = axis_normal × tangent1
        const cross2 = [3]f32{
            axis_normal[1] * tangent1[2] - axis_normal[2] * tangent1[1],
            axis_normal[2] * tangent1[0] - axis_normal[0] * tangent1[2],
            axis_normal[0] * tangent1[1] - axis_normal[1] * tangent1[0],
        };
        const len2 = @sqrt(cross2[0] * cross2[0] + cross2[1] * cross2[1] + cross2[2] * cross2[2]);
        tangent2 = .{ cross2[0] / len2, cross2[1] / len2, cross2[2] / len2 };

        // Draw circle as line segments
        var prev_screen: ?[2]f32 = null;
        var i: i32 = 0;
        while (i <= num_segments) : (i += 1) {
            const angle = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(num_segments));
            const cos_a = @cos(angle);
            const sin_a = @sin(angle);

            // Point on circle in 3D space
            const world_point = [3]f32{
                self.position[0] + (tangent1[0] * cos_a + tangent2[0] * sin_a) * radius * 0.01,
                self.position[1] + (tangent1[1] * cos_a + tangent2[1] * sin_a) * radius * 0.01,
                self.position[2] + (tangent1[2] * cos_a + tangent2[2] * sin_a) * radius * 0.01,
            };

            if (self.worldToScreen(world_point)) |screen_point| {
                if (prev_screen) |prev| {
                    imgui.drawListAddLineEx(
                        draw_list,
                        .{ .x = prev[0], .y = prev[1] },
                        .{ .x = screen_point[0], .y = screen_point[1] },
                        color,
                        thickness,
                    );
                }
                prev_screen = screen_point;
            } else {
                prev_screen = null;
            }
        }
    }

    /// Render a small orientation indicator in the top-right corner.
    /// This shows the current scene orientation similar to Unity/Unreal.
    pub fn renderOrientationIndicator(self: *Gizmo) void {
        if (!self.use_world_position) return; // Need view projection matrix

        const draw_list = imgui.getForegroundDrawList();
        const io = imgui.getIO();
        const display_size = io.*.DisplaySize;

        // Position in top-right corner
        const margin: f32 = 60;
        const center_x = display_size.x - margin;
        const center_y = margin;
        const size: f32 = 40;

        // Colors (ABGR format)
        const x_color: u32 = 0xFF0000FF; // Red
        const y_color: u32 = 0xFF00FF00; // Green
        const z_color: u32 = 0xFFFF0000; // Blue
        const bg_color: u32 = 0xAA1A1A1A; // Semi-transparent dark background

        // Draw background circle
        imgui.drawListAddCircleFilled(draw_list, .{ .x = center_x, .y = center_y }, size + 5, bg_color, 32);

        // Project world axes from origin
        const origin = [3]f32{ 0, 0, 0 };
        const x_axis = self.projectWorldAxis(origin, .{ 1, 0, 0 }, size);
        const y_axis = self.projectWorldAxis(origin, .{ 0, 1, 0 }, size);
        const z_axis = self.projectWorldAxis(origin, .{ 0, 0, 1 }, size);

        // Calculate endpoints relative to indicator center
        const x_end = [2]f32{ center_x + x_axis.direction[0] * size, center_y + x_axis.direction[1] * size };
        const y_end = [2]f32{ center_x + y_axis.direction[0] * size, center_y + y_axis.direction[1] * size };
        const z_end = [2]f32{ center_x + z_axis.direction[0] * size, center_y + z_axis.direction[1] * size };

        // Calculate depth for proper draw order (which axes are closer to camera)
        // We can use the Z component of the transformed direction to determine depth
        const x_depth = self.getAxisDepth(.{ 1, 0, 0 });
        const y_depth = self.getAxisDepth(.{ 0, 1, 0 });
        const z_depth = self.getAxisDepth(.{ 0, 0, 1 });

        // Sort axes by depth (draw furthest first)
        const AxisDraw = struct {
            depth: f32,
            end: [2]f32,
            color: u32,
            label: [*:0]const u8,
        };

        var axes = [3]AxisDraw{
            .{ .depth = x_depth, .end = x_end, .color = x_color, .label = "X" },
            .{ .depth = y_depth, .end = y_end, .color = y_color, .label = "Y" },
            .{ .depth = z_depth, .end = z_end, .color = z_color, .label = "Z" },
        };

        // Simple bubble sort by depth (furthest first)
        for (0..axes.len) |i| {
            for (i + 1..axes.len) |j| {
                if (axes[i].depth > axes[j].depth) {
                    const temp = axes[i];
                    axes[i] = axes[j];
                    axes[j] = temp;
                }
            }
        }

        // Draw axes in order (furthest to nearest)
        const thickness: f32 = 2.5;
        for (axes) |axis| {
            // Darken color if pointing away from camera (negative depth)
            const color = if (axis.depth < 0) blendColor(axis.color, 0xFF000000, 0.5) else axis.color;

            imgui.drawListAddLineEx(
                draw_list,
                .{ .x = center_x, .y = center_y },
                .{ .x = axis.end[0], .y = axis.end[1] },
                color,
                thickness,
            );

            // Draw label
            imgui.drawListAddText(
                draw_list,
                .{ .x = axis.end[0] + 3, .y = axis.end[1] - 8 },
                color,
                axis.label,
            );
        }

        // Draw center dot
        imgui.drawListAddCircleFilled(draw_list, .{ .x = center_x, .y = center_y }, 3, 0xFFFFFFFF, 12);
    }

    /// Get the depth of an axis direction (positive = towards camera, negative = away)
    fn getAxisDepth(self: *Gizmo, axis_dir: [3]f32) f32 {
        // Transform axis direction by view matrix (just rotation part)
        // We can use the Z component of the view-space direction
        const z = self.view_proj.data[2] * axis_dir[0] + self.view_proj.data[6] * axis_dir[1] + self.view_proj.data[10] * axis_dir[2];
        return -z; // Negate because in view space, -Z is forward
    }
};

/// Blend two colors together
fn blendColor(color1: u32, color2: u32, t: f32) u32 {
    const r1 = @as(f32, @floatFromInt((color1 >> 0) & 0xFF));
    const g1 = @as(f32, @floatFromInt((color1 >> 8) & 0xFF));
    const b1 = @as(f32, @floatFromInt((color1 >> 16) & 0xFF));
    const a1 = @as(f32, @floatFromInt((color1 >> 24) & 0xFF));

    const r2 = @as(f32, @floatFromInt((color2 >> 0) & 0xFF));
    const g2 = @as(f32, @floatFromInt((color2 >> 8) & 0xFF));
    const b2 = @as(f32, @floatFromInt((color2 >> 16) & 0xFF));
    const a2 = @as(f32, @floatFromInt((color2 >> 24) & 0xFF));

    const r = @as(u32, @intFromFloat(r1 * (1.0 - t) + r2 * t));
    const g = @as(u32, @intFromFloat(g1 * (1.0 - t) + g2 * t));
    const b = @as(u32, @intFromFloat(b1 * (1.0 - t) + b2 * t));
    const a = @as(u32, @intFromFloat(a1 * (1.0 - t) + a2 * t));

    return r | (g << 8) | (b << 16) | (a << 24);
}

/// Calculate distance from point to line segment.
fn pointToLineDistance(px: f32, py: f32, x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len_sq = dx * dx + dy * dy;

    if (len_sq == 0) {
        // Line segment is a point
        const pdx = px - x1;
        const pdy = py - y1;
        return @sqrt(pdx * pdx + pdy * pdy);
    }

    // Parameter t for the closest point on the line
    var t = ((px - x1) * dx + (py - y1) * dy) / len_sq;
    t = @max(0, @min(1, t));

    // Closest point on line
    const closest_x = x1 + t * dx;
    const closest_y = y1 + t * dy;

    // Distance to closest point
    const dist_x = px - closest_x;
    const dist_y = py - closest_y;
    return @sqrt(dist_x * dist_x + dist_y * dist_y);
}
