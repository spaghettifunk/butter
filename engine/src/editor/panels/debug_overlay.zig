//! Debug Overlay
//! Displays FPS, frame time, and object information as a screen overlay.

const std = @import("std");
const imgui = @import("../../systems/imgui.zig");
const input = @import("../../systems/input.zig");

const c = imgui.c;

/// Number of frame times to track for averaging.
const frame_time_history = 120;

pub const DebugOverlay = struct {
    /// Whether the overlay is currently visible.
    is_visible: bool = true,

    /// Ring buffer of frame times (in seconds).
    frame_times: [frame_time_history]f32 = [_]f32{0} ** frame_time_history,

    /// Current index in the ring buffer.
    frame_time_index: usize = 0,

    /// Calculated FPS.
    fps: f32 = 0,

    /// Calculated frame time in milliseconds.
    frame_time_ms: f32 = 0,

    /// Name of the object currently hovered (if any).
    hovered_object_name: ?[]const u8 = null,

    /// ID of the object currently hovered.
    hovered_object_id: u32 = 0,

    /// Material name of the hovered object.
    hovered_object_material: ?[]const u8 = null,

    /// Position of the hovered object.
    hovered_object_position: [3]f32 = .{ 0, 0, 0 },

    /// Update the overlay with the current frame's delta time.
    pub fn update(self: *DebugOverlay, delta_time: f32) void {
        // Update frame time ring buffer
        self.frame_times[self.frame_time_index] = delta_time;
        self.frame_time_index = (self.frame_time_index + 1) % frame_time_history;

        // Calculate average frame time
        var sum: f32 = 0;
        for (self.frame_times) |t| {
            sum += t;
        }
        self.frame_time_ms = (sum / @as(f32, @floatFromInt(frame_time_history))) * 1000.0;
        self.fps = if (self.frame_time_ms > 0) 1000.0 / self.frame_time_ms else 0;
    }

    /// Set information about the currently hovered object.
    pub fn setHoveredObject(
        self: *DebugOverlay,
        name: ?[]const u8,
        id: u32,
        material: ?[]const u8,
        position: [3]f32,
    ) void {
        self.hovered_object_name = name;
        self.hovered_object_id = id;
        self.hovered_object_material = material;
        self.hovered_object_position = position;
    }

    /// Clear the hovered object information.
    pub fn clearHoveredObject(self: *DebugOverlay) void {
        self.hovered_object_name = null;
        self.hovered_object_id = 0;
        self.hovered_object_material = null;
    }

    /// Render the debug overlay.
    pub fn render(self: *DebugOverlay) void {
        if (!self.is_visible) return;

        const draw_list = imgui.getForegroundDrawList();

        // Colors
        const bg_color: u32 = 0xCC1A1A1A; // Semi-transparent dark gray
        const text_color: u32 = 0xFFFFFFFF; // White
        const fps_color: u32 = self.getFpsColor();
        const label_color: u32 = 0xFFAAAAAA; // Light gray

        // FPS panel position and size (bottom-left corner)
        const panel_padding: f32 = 8;
        const line_height: f32 = 18;
        const panel_width: f32 = 180;
        const panel_height: f32 = panel_padding * 2 + line_height * 3;

        // Get display size and position at bottom-left
        const io = imgui.getIO();
        const display_size = io.*.DisplaySize;
        const panel_x: f32 = display_size.x - panel_width - 10;
        const panel_y: f32 = display_size.y - panel_height - 10;

        // Draw FPS panel background
        imgui.drawListAddRectFilledEx(
            draw_list,
            .{ .x = panel_x, .y = panel_y },
            .{ .x = panel_x + panel_width, .y = panel_y + panel_height },
            bg_color,
            5.0,
            0,
        );

        // Draw FPS text
        var buf: [128]u8 = undefined;

        // FPS
        const fps_text = std.fmt.bufPrintZ(&buf, "FPS: {d:.1}", .{self.fps}) catch "FPS: ???";
        imgui.drawListAddText(
            draw_list,
            .{ .x = panel_x + panel_padding, .y = panel_y + panel_padding },
            fps_color,
            fps_text.ptr,
        );

        // Frame time
        const frame_text = std.fmt.bufPrintZ(&buf, "Frame: {d:.2}ms", .{self.frame_time_ms}) catch "Frame: ???";
        imgui.drawListAddText(
            draw_list,
            .{ .x = panel_x + panel_padding, .y = panel_y + panel_padding + line_height },
            text_color,
            frame_text.ptr,
        );

        // Mouse position
        const mouse_pos = input.getMousePosition();
        const mouse_text = std.fmt.bufPrintZ(&buf, "Mouse: ({d:.0}, {d:.0})", .{ mouse_pos.x, mouse_pos.y }) catch "Mouse: ???";
        imgui.drawListAddText(
            draw_list,
            .{ .x = panel_x + panel_padding, .y = panel_y + panel_padding + line_height * 2 },
            label_color,
            mouse_text.ptr,
        );

        // Hovered object tooltip
        if (self.hovered_object_name) |name| {
            const tooltip_x = @as(f32, @floatCast(mouse_pos.x)) + 15;
            const tooltip_y = @as(f32, @floatCast(mouse_pos.y)) + 15;
            const tooltip_width: f32 = 220;
            var tooltip_height: f32 = panel_padding * 2 + line_height * 2;

            if (self.hovered_object_material != null) {
                tooltip_height += line_height;
            }
            tooltip_height += line_height; // Position line

            // Tooltip background
            imgui.drawListAddRectFilledEx(
                draw_list,
                .{ .x = tooltip_x, .y = tooltip_y },
                .{ .x = tooltip_x + tooltip_width, .y = tooltip_y + tooltip_height },
                bg_color,
                3.0,
                0,
            );

            var y_offset: f32 = tooltip_y + panel_padding;

            // Object name
            const name_text = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch "???";
            imgui.drawListAddText(
                draw_list,
                .{ .x = tooltip_x + panel_padding, .y = y_offset },
                0xFFFFFF00, // Yellow
                name_text.ptr,
            );
            y_offset += line_height;

            // Object ID
            const id_text = std.fmt.bufPrintZ(&buf, "ID: {}", .{self.hovered_object_id}) catch "ID: ???";
            imgui.drawListAddText(
                draw_list,
                .{ .x = tooltip_x + panel_padding, .y = y_offset },
                label_color,
                id_text.ptr,
            );
            y_offset += line_height;

            // Material
            if (self.hovered_object_material) |material| {
                const mat_text = std.fmt.bufPrintZ(&buf, "Material: {s}", .{material}) catch "Material: ???";
                imgui.drawListAddText(
                    draw_list,
                    .{ .x = tooltip_x + panel_padding, .y = y_offset },
                    label_color,
                    mat_text.ptr,
                );
                y_offset += line_height;
            }

            // Position
            const pos_text = std.fmt.bufPrintZ(&buf, "Pos: ({d:.1}, {d:.1}, {d:.1})", .{
                self.hovered_object_position[0],
                self.hovered_object_position[1],
                self.hovered_object_position[2],
            }) catch "Pos: ???";
            imgui.drawListAddText(
                draw_list,
                .{ .x = tooltip_x + panel_padding, .y = y_offset },
                label_color,
                pos_text.ptr,
            );
        }
    }

    /// Get color for FPS based on value (green/yellow/red).
    fn getFpsColor(self: *DebugOverlay) u32 {
        if (self.fps >= 55) {
            return 0xFF00FF00; // Green
        } else if (self.fps >= 30) {
            return 0xFF00FFFF; // Yellow
        } else {
            return 0xFF0000FF; // Red
        }
    }
};
