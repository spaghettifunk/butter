//! Light Debug Visualization
//! Provides visual debugging overlays for lights in the scene:
//! - Direction arrows for directional lights
//! - Range spheres for point lights

const std = @import("std");
const imgui = @import("../systems/imgui.zig");
const math = @import("../math/math.zig");
const renderer = @import("../renderer/renderer.zig");
const light_system = @import("../systems/light.zig");

/// Global toggle for light debug visualization
pub var enabled: bool = false;

/// Render debug visualization for all lights
pub fn render(view_proj: math.Mat4, screen_width: f32, screen_height: f32) void {
    if (!enabled) return;

    const render_sys = renderer.getSystem() orelse return;
    const ls = if (render_sys.light_system) |*s| s else return;

    const draw_list = imgui.getForegroundDrawList();

    // Render debug visualization for each light
    for (ls.lights.items) |*light| {
        if (!light.enabled) continue;

        switch (light.type) {
            .directional => drawDirectionalDebug(draw_list, light, view_proj, screen_width, screen_height),
            .point => drawPointDebug(draw_list, light, view_proj, screen_width, screen_height),
            .spot => {}, // Not implemented yet
        }
    }
}

/// Draw debug visualization for a directional light (arrow showing direction)
fn drawDirectionalDebug(
    draw_list: *imgui.ImDrawList,
    light: *const light_system.Light,
    view_proj: math.Mat4,
    screen_width: f32,
    screen_height: f32,
) void {
    const arrow_length: f32 = 2.0;

    // Calculate arrow start and end points
    const start_pos = light.position;
    const end_pos: [3]f32 = .{
        start_pos[0] + light.direction[0] * arrow_length,
        start_pos[1] + light.direction[1] * arrow_length,
        start_pos[2] + light.direction[2] * arrow_length,
    };

    // Project to screen space
    const screen_start = worldToScreen(start_pos, view_proj, screen_width, screen_height) orelse return;
    const screen_end = worldToScreen(end_pos, view_proj, screen_width, screen_height) orelse return;

    const color: u32 = 0xFFFFFF00; // Yellow

    // Draw arrow line
    imgui.drawListAddLineEx(
        draw_list,
        .{ .x = screen_start[0], .y = screen_start[1] },
        .{ .x = screen_end[0], .y = screen_end[1] },
        color,
        3.0,
    );

    // Draw arrow head (simple triangle)
    const arrow_size: f32 = 10.0;
    const dx = screen_end[0] - screen_start[0];
    const dy = screen_end[1] - screen_start[1];
    const angle = std.math.atan2(dy, dx);

    const head_angle1 = angle + std.math.pi * 0.75;
    const head_angle2 = angle - std.math.pi * 0.75;

    const head1_x = screen_end[0] + @cos(head_angle1) * arrow_size;
    const head1_y = screen_end[1] + @sin(head_angle1) * arrow_size;
    const head2_x = screen_end[0] + @cos(head_angle2) * arrow_size;
    const head2_y = screen_end[1] + @sin(head_angle2) * arrow_size;

    imgui.drawListAddTriangleFilled(
        draw_list,
        .{ .x = screen_end[0], .y = screen_end[1] },
        .{ .x = head1_x, .y = head1_y },
        .{ .x = head2_x, .y = head2_y },
        color,
    );
}

/// Draw debug visualization for a point light (wireframe sphere at range distance)
fn drawPointDebug(
    draw_list: *imgui.ImDrawList,
    light: *const light_system.Light,
    view_proj: math.Mat4,
    screen_width: f32,
    screen_height: f32,
) void {
    const num_segments: usize = 32;
    const color: u32 = 0xFF00FFFF; // Cyan

    // Draw three circles (XY, XZ, YZ planes) to approximate sphere
    drawCircle3D(draw_list, light.position, light.range, .xy, view_proj, screen_width, screen_height, color, num_segments);
    drawCircle3D(draw_list, light.position, light.range, .xz, view_proj, screen_width, screen_height, color, num_segments);
    drawCircle3D(draw_list, light.position, light.range, .yz, view_proj, screen_width, screen_height, color, num_segments);
}

/// Plane for circle rendering
const Plane = enum { xy, xz, yz };

/// Draw a 3D circle in the specified plane
fn drawCircle3D(
    draw_list: *imgui.ImDrawList,
    center: [3]f32,
    radius: f32,
    plane: Plane,
    view_proj: math.Mat4,
    screen_width: f32,
    screen_height: f32,
    color: u32,
    segments: usize,
) void {
    var prev_screen_pos: ?[2]f32 = null;

    var i: usize = 0;
    while (i <= segments) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(segments));
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);

        // Calculate world position based on plane
        const world_pos: [3]f32 = switch (plane) {
            .xy => .{ center[0] + cos_a * radius, center[1] + sin_a * radius, center[2] },
            .xz => .{ center[0] + cos_a * radius, center[1], center[2] + sin_a * radius },
            .yz => .{ center[0], center[1] + cos_a * radius, center[2] + sin_a * radius },
        };

        // Project to screen
        const screen_pos = worldToScreen(world_pos, view_proj, screen_width, screen_height) orelse continue;

        // Draw line segment if we have a previous point
        if (prev_screen_pos) |prev| {
            imgui.drawListAddLineEx(
                draw_list,
                .{ .x = prev[0], .y = prev[1] },
                .{ .x = screen_pos[0], .y = screen_pos[1] },
                color,
                1.0,
            );
        }

        prev_screen_pos = screen_pos;
    }
}

/// Project world position to screen coordinates
fn worldToScreen(world_pos: [3]f32, view_proj: math.Mat4, screen_width: f32, screen_height: f32) ?[2]f32 {
    // Transform to clip space
    const x = view_proj.data[0] * world_pos[0] + view_proj.data[4] * world_pos[1] + view_proj.data[8] * world_pos[2] + view_proj.data[12];
    const y = view_proj.data[1] * world_pos[0] + view_proj.data[5] * world_pos[1] + view_proj.data[9] * world_pos[2] + view_proj.data[13];
    const w = view_proj.data[3] * world_pos[0] + view_proj.data[7] * world_pos[1] + view_proj.data[11] * world_pos[2] + view_proj.data[15];

    // Behind camera check
    if (w <= 0.001) return null;

    // Perspective divide to NDC
    const ndc_x = x / w;
    const ndc_y = y / w;

    // Convert to screen coordinates
    const screen_x = (ndc_x + 1.0) * 0.5 * screen_width;
    const screen_y = (1.0 - ndc_y) * 0.5 * screen_height; // Flip Y

    return .{ screen_x, screen_y };
}
