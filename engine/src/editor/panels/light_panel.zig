//! Light Panel
//! Provides a UI for editing light properties and shadow settings.

const std = @import("std");
const imgui = @import("../../systems/imgui.zig");
const selection_mod = @import("../selection.zig");
const renderer = @import("../../renderer/renderer.zig");
const light_system = @import("../../systems/light.zig");

const Selection = selection_mod.Selection;
const LightType = light_system.LightType;
const ShadowType = light_system.ShadowType;

// Module state
var selection: ?*Selection = null;

pub fn init() void {
    // State is set via setContext
}

pub fn shutdown() void {
    selection = null;
}

/// Set the selection context for the light panel
pub fn setContext(sel: *Selection) void {
    selection = sel;
}

pub fn render(p_open: *bool) void {
    if (imgui.begin("Light Panel", p_open, 0)) {
        const sel = selection orelse {
            imgui.text("(Light panel not initialized)");
            imgui.end();
            return;
        };

        const render_sys = renderer.getSystem() orelse {
            imgui.text("(No renderer system)");
            imgui.end();
            return;
        };

        // Get pointer to light system to avoid copies and allow mutation
        const ls = if (render_sys.light_system) |*s| s else {
            imgui.text("(No light system)");
            imgui.end();
            return;
        };

        // Light selection list
        imgui.text("Select Light:");
        if (imgui.beginChild("LightList", .{ .x = 0, .y = 100 }, imgui.ChildFlags.Border, 0)) {
            for (ls.lights.items) |*light| {
                var buf: [128:0]u8 = undefined;
                const label = std.fmt.bufPrintZ(&buf, "Light {d} ({s})", .{ light.id, @tagName(light.type) }) catch "Light";

                const is_selected = (sel.selected_light_id == light.id);
                if (imgui.selectableEx(label, is_selected, 0, .{ .x = 0, .y = 0 })) {
                    sel.selectLight(light.id);
                }
            }
        }
        imgui.endChild();

        imgui.spacing();
        imgui.separator();
        imgui.spacing();

        const selected_light = if (sel.selected_light_id != 0) ls.getLightById(sel.selected_light_id) else ls.getMainLight();

        if (selected_light) |light| {
            imgui.text("Light Properties");
            imgui.spacing();

            // Light Type
            imgui.text("Type:");
            imgui.sameLine();
            const type_label: [*:0]const u8 = @ptrCast(@tagName(light.type));
            if (imgui.button(type_label)) {
                // Simplified cycle through types
                light.type = switch (light.type) {
                    .directional => .point,
                    .point => .spot,
                    .spot => .directional,
                };
            }

            imgui.spacing();

            // Intensity (Sliding bar - sliderFloat)
            imgui.text("Intensity");
            _ = imgui.sliderFloat("##intensity", &light.intensity, 0.0, 10.0);

            // Color (Slider/ColorPicker)
            imgui.text("Color");
            _ = imgui.colorEdit3("##color", &light.color);

            // Range (Slider)
            imgui.text("Range");
            _ = imgui.sliderFloat("##range", &light.range, 0.0, 100.0);

            imgui.spacing();
            imgui.separator();
            imgui.spacing();

            // Shadow Type
            imgui.text("Shadows:");
            imgui.sameLine();
            const shadow_label: [*:0]const u8 = @ptrCast(@tagName(light.shadow_type));
            if (imgui.button(shadow_label)) {
                light.shadow_type = switch (light.shadow_type) {
                    .none => .hard,
                    .hard => .soft,
                    .soft => .none,
                };
            }

            imgui.spacing();
            _ = imgui.checkbox("Enabled", &light.enabled);
        } else {
            imgui.textDisabled("No light selected. Select from the list above.");
        }
    }
    imgui.end();
}
