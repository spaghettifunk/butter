//! Gizmo Panel
//! Provides a UI for editing object transforms via sliders.

const std = @import("std");
const imgui = @import("../../systems/imgui.zig");
const editor_scene = @import("../editor_scene.zig");
const selection_mod = @import("../selection.zig");

const EditorScene = editor_scene.EditorScene;
const Selection = selection_mod.Selection;

// Module state
var scene: ?*EditorScene = null;
var selection: ?*Selection = null;

pub fn init() void {
    // State is set via setContext
}

pub fn shutdown() void {
    scene = null;
    selection = null;
}

/// Set the scene and selection context for the gizmo panel
pub fn setContext(s: *EditorScene, sel: *Selection) void {
    scene = s;
    selection = sel;
}

pub fn render(p_open: *bool) void {
    if (imgui.begin("Gizmo Panel", p_open, 0)) {
        const sel = selection orelse {
            imgui.text("(Gizmo panel not initialized)");
            imgui.end();
            return;
        };

        const sc = scene orelse {
            imgui.text("(No scene)");
            imgui.end();
            return;
        };

        const selected_id = sel.getSelected() orelse {
            imgui.text("(No object selected)");
            imgui.spacing();
            imgui.textDisabled("Select an object to edit its transform");
            imgui.end();
            return;
        };

        const obj = sc.getObject(selected_id) orelse {
            imgui.text("(Invalid selection)");
            imgui.end();
            return;
        };

        // Object header
        imgui.text("Selected Object:");
        imgui.sameLine();
        const name_ptr: [*:0]const u8 = @ptrCast(&obj.name);
        imgui.text(name_ptr);
        imgui.separator();

        var changed = false;

        // Translation (Slidng bars as requested)
        imgui.text("Translation");
        if (imgui.sliderFloat("X##pos", &obj.transform.position[0], -50.0, 50.0)) changed = true;
        if (imgui.sliderFloat("Y##pos", &obj.transform.position[1], -50.0, 50.0)) changed = true;
        if (imgui.sliderFloat("Z##pos", &obj.transform.position[2], -50.0, 50.0)) changed = true;

        imgui.spacing();
        imgui.separator();
        imgui.spacing();

        // Rotation (Sliders)
        imgui.text("Rotation");
        if (imgui.sliderFloat("X##rot", &obj.transform.rotation[0], -180.0, 180.0)) changed = true;
        if (imgui.sliderFloat("Y##rot", &obj.transform.rotation[1], -180.0, 180.0)) changed = true;
        if (imgui.sliderFloat("Z##rot", &obj.transform.rotation[2], -180.0, 180.0)) changed = true;

        imgui.spacing();
        imgui.separator();
        imgui.spacing();

        // Scale (Sliders)
        imgui.text("Scale");
        if (imgui.sliderFloat("X##scl", &obj.transform.scale[0], 0.01, 10.0)) changed = true;
        if (imgui.sliderFloat("Y##scl", &obj.transform.scale[1], 0.01, 10.0)) changed = true;
        if (imgui.sliderFloat("Z##scl", &obj.transform.scale[2], 0.01, 10.0)) changed = true;

        if (changed) {
            sc.updateBounds(obj);
        }
    }
    imgui.end();
}
