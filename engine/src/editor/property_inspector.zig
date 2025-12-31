//! Property Inspector Panel
//! Displays and allows editing of selected object properties.

const std = @import("std");
const imgui = @import("../systems/imgui.zig");
const editor_scene = @import("editor_scene.zig");
const selection_mod = @import("selection.zig");

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

/// Set the scene and selection context for the property inspector
pub fn setContext(s: *EditorScene, sel: *Selection) void {
    scene = s;
    selection = sel;
}

pub fn render(p_open: *bool) void {
    if (imgui.begin("Property Inspector", p_open, 0)) {
        const sel = selection orelse {
            imgui.text("(Property inspector not initialized)");
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
            imgui.textDisabled("Click on an object to select it");
            imgui.end();
            return;
        };

        const obj = sc.getObject(selected_id) orelse {
            imgui.text("(Invalid selection)");
            imgui.end();
            return;
        };

        // Object header
        imgui.text("Object:");
        imgui.sameLine();
        // Get name as sentinel-terminated pointer
        const name_ptr: [*:0]const u8 = @ptrCast(&obj.name);
        imgui.text(name_ptr);
        imgui.separator();

        // Transform section
        if (imgui.collapsingHeader("Transform")) {
            var transform_changed = false;

            imgui.text("Position");
            if (imgui.dragFloat3("##pos", &obj.transform.position, 0.1)) {
                transform_changed = true;
            }

            imgui.text("Rotation");
            if (imgui.dragFloat3("##rot", &obj.transform.rotation, 1.0)) {
                transform_changed = true;
            }

            imgui.text("Scale");
            if (imgui.dragFloat3("##scl", &obj.transform.scale, 0.1)) {
                transform_changed = true;
            }

            // Update bounds if transform changed
            if (transform_changed) {
                sc.updateBounds(obj);
            }
        }

        // Visibility toggle
        imgui.separator();
        _ = imgui.checkbox("Visible", &obj.is_visible);

        // Object info section (collapsed by default)
        if (imgui.collapsingHeader("Info")) {
            imgui.text("Object Details");
            imgui.textDisabled("(ID and geometry info displayed here)");
        }
    }
    imgui.end();
}
