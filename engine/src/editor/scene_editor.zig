//! Scene Editor Panel
//! Displays the scene hierarchy as a list of objects.

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

/// Set the scene and selection context for the scene editor
pub fn setContext(s: *EditorScene, sel: *Selection) void {
    scene = s;
    selection = sel;
}

pub fn render(p_open: *bool) void {
    if (imgui.begin("Scene Hierarchy", p_open, 0)) {
        const sc = scene orelse {
            imgui.text("(No scene)");
            imgui.end();
            return;
        };

        const sel = selection orelse {
            imgui.text("(Selection not initialized)");
            imgui.end();
            return;
        };

        const objects = sc.getAllObjects();
        if (objects.len == 0) {
            imgui.text("(No objects in scene)");
            imgui.spacing();
            imgui.textDisabled("Add objects via game.zig");
        } else {
            // Header
            imgui.text("Objects:");
            imgui.separator();

            // List all objects
            for (objects) |*obj| {
                const is_selected = sel.isSelected(obj.id);
                const name_slice = std.mem.sliceTo(&obj.name, 0);

                // Create a selectable item
                if (imgui.selectableEx(@ptrCast(name_slice.ptr), is_selected, 0, .{ .x = 0, .y = 0 })) {
                    // Toggle selection on click
                    if (is_selected) {
                        sel.deselect();
                    } else {
                        sel.select(obj.id);
                    }
                }
            }
        }

        imgui.separator();

        // Object count
        imgui.textDisabled("Objects:");
        imgui.sameLine();
        // Just show a simple count indicator
        if (objects.len == 0) {
            imgui.text("0");
        } else if (objects.len == 1) {
            imgui.text("1");
        } else if (objects.len == 2) {
            imgui.text("2");
        } else if (objects.len == 3) {
            imgui.text("3");
        } else {
            imgui.text("4+");
        }
    }
    imgui.end();
}
