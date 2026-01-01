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

        self.hovered_axis = self.checkAxisHover(mx, my, center_x, center_y, axis_length);

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
                // X axis (right)
                const x_col = if (self.hovered_axis == .x or self.dragging_axis == .x) hover_color else x_color;
                imgui.drawListAddLineEx(
                    draw_list,
                    .{ .x = center_x, .y = center_y },
                    .{ .x = center_x + axis_length, .y = center_y },
                    x_col,
                    axis_thickness,
                );
                // Arrow head
                imgui.drawListAddTriangleFilled(
                    draw_list,
                    .{ .x = center_x + axis_length + arrow_size, .y = center_y },
                    .{ .x = center_x + axis_length, .y = center_y - arrow_size / 2 },
                    .{ .x = center_x + axis_length, .y = center_y + arrow_size / 2 },
                    x_col,
                );

                // Y axis (up)
                const y_col = if (self.hovered_axis == .y or self.dragging_axis == .y) hover_color else y_color;
                imgui.drawListAddLineEx(
                    draw_list,
                    .{ .x = center_x, .y = center_y },
                    .{ .x = center_x, .y = center_y - axis_length },
                    y_col,
                    axis_thickness,
                );
                // Arrow head
                imgui.drawListAddTriangleFilled(
                    draw_list,
                    .{ .x = center_x, .y = center_y - axis_length - arrow_size },
                    .{ .x = center_x - arrow_size / 2, .y = center_y - axis_length },
                    .{ .x = center_x + arrow_size / 2, .y = center_y - axis_length },
                    y_col,
                );

                // Z axis (diagonal, towards viewer)
                const z_col = if (self.hovered_axis == .z or self.dragging_axis == .z) hover_color else z_color;
                const z_end_x = center_x + axis_length * 0.7;
                const z_end_y = center_y + axis_length * 0.7;
                imgui.drawListAddLineEx(
                    draw_list,
                    .{ .x = center_x, .y = center_y },
                    .{ .x = z_end_x, .y = z_end_y },
                    z_col,
                    axis_thickness,
                );
                // Labels
                imgui.drawListAddText(draw_list, .{ .x = center_x + axis_length + arrow_size + 5, .y = center_y - 7 }, x_col, "X");
                imgui.drawListAddText(draw_list, .{ .x = center_x - 4, .y = center_y - axis_length - arrow_size - 15 }, y_col, "Y");
                imgui.drawListAddText(draw_list, .{ .x = z_end_x + 5, .y = z_end_y + 5 }, z_col, "Z");
            },
            .rotate => {
                // Draw rotation circles
                const radius: f32 = axis_length * 0.8;

                // X rotation (YZ plane)
                const x_col = if (self.hovered_axis == .x or self.dragging_axis == .x) hover_color else x_color;
                imgui.drawListAddCircleEx(draw_list, .{ .x = center_x, .y = center_y }, radius, x_col, 32, axis_thickness);
                imgui.drawListAddText(draw_list, .{ .x = center_x + radius * 0.7 + 5, .y = center_y - radius * 0.7 - 7 }, x_col, "X");

                // Y rotation (XZ plane) - draw as ellipse
                const y_col = if (self.hovered_axis == .y or self.dragging_axis == .y) hover_color else y_color;
                imgui.drawListAddEllipseEx(draw_list, .{ .x = center_x, .y = center_y }, .{ .x = radius, .y = radius * 0.3 }, y_col, 0, 32, axis_thickness);
                imgui.drawListAddText(draw_list, .{ .x = center_x + radius + 10, .y = center_y - 7 }, y_col, "Y");

                // Z rotation (XY plane) - draw as ellipse
                const z_col = if (self.hovered_axis == .z or self.dragging_axis == .z) hover_color else z_color;
                imgui.drawListAddEllipseEx(draw_list, .{ .x = center_x, .y = center_y }, .{ .x = radius * 0.3, .y = radius }, z_col, 0, 32, axis_thickness);
                imgui.drawListAddText(draw_list, .{ .x = center_x - 4, .y = center_y - radius - 15 }, z_col, "Z");
            },
            .scale => {
                // X axis with box
                const x_col = if (self.hovered_axis == .x or self.dragging_axis == .x) hover_color else x_color;
                imgui.drawListAddLineEx(
                    draw_list,
                    .{ .x = center_x, .y = center_y },
                    .{ .x = center_x + axis_length, .y = center_y },
                    x_col,
                    axis_thickness,
                );
                imgui.drawListAddRectFilled(
                    draw_list,
                    .{ .x = center_x + axis_length - 5, .y = center_y - 5 },
                    .{ .x = center_x + axis_length + 5, .y = center_y + 5 },
                    x_col,
                );
                imgui.drawListAddText(draw_list, .{ .x = center_x + axis_length + 10, .y = center_y - 7 }, x_col, "X");

                // Y axis with box
                const y_col = if (self.hovered_axis == .y or self.dragging_axis == .y) hover_color else y_color;
                imgui.drawListAddLineEx(
                    draw_list,
                    .{ .x = center_x, .y = center_y },
                    .{ .x = center_x, .y = center_y - axis_length },
                    y_col,
                    axis_thickness,
                );
                imgui.drawListAddRectFilled(
                    draw_list,
                    .{ .x = center_x - 5, .y = center_y - axis_length - 5 },
                    .{ .x = center_x + 5, .y = center_y - axis_length + 5 },
                    y_col,
                );
                imgui.drawListAddText(draw_list, .{ .x = center_x - 4, .y = center_y - axis_length - 20 }, y_col, "Y");

                // Z axis with box
                const z_col = if (self.hovered_axis == .z or self.dragging_axis == .z) hover_color else z_color;
                const z_end_x = center_x + axis_length * 0.7;
                const z_end_y = center_y + axis_length * 0.7;
                imgui.drawListAddLineEx(
                    draw_list,
                    .{ .x = center_x, .y = center_y },
                    .{ .x = z_end_x, .y = z_end_y },
                    z_col,
                    axis_thickness,
                );
                imgui.drawListAddRectFilled(
                    draw_list,
                    .{ .x = z_end_x - 5, .y = z_end_y - 5 },
                    .{ .x = z_end_x + 5, .y = z_end_y + 5 },
                    z_col,
                );
                imgui.drawListAddText(draw_list, .{ .x = z_end_x + 10, .y = z_end_y + 5 }, z_col, "Z");

                // Center cube for uniform scale
                const all_col = if (self.hovered_axis == .all or self.dragging_axis == .all) hover_color else text_color;
                imgui.drawListAddRectFilled(
                    draw_list,
                    .{ .x = center_x - 8, .y = center_y - 8 },
                    .{ .x = center_x + 8, .y = center_y + 8 },
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

    /// Check which axis is being hovered.
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
                switch (self.dragging_axis) {
                    .x => delta.position[0] = dx * sensitivity,
                    .y => delta.position[1] = -dy * sensitivity,
                    .z => {
                        const avg = (dx + dy) * 0.5;
                        delta.position[2] = avg * sensitivity;
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
                    .x => delta.scale[0] = 1.0 + dx * scale_sensitivity,
                    .y => delta.scale[1] = 1.0 - dy * scale_sensitivity,
                    .z => {
                        const avg = (dx + dy) * 0.5;
                        delta.scale[2] = 1.0 + avg * scale_sensitivity;
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
};

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
