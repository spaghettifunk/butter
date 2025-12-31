//! Asset Browser Panel
//! Displays and allows browsing of project assets.
//! This is a stub implementation - expand with actual file browsing.

const imgui = @import("../systems/imgui.zig");

pub fn init() void {
    // TODO: Initialize asset browser state, scan asset directories
}

pub fn shutdown() void {
    // TODO: Cleanup asset browser state
}

pub fn render(p_open: *bool) void {
    if (imgui.begin("Asset Browser", p_open, 0)) {
        imgui.text("Asset Browser");
        imgui.separator();
        imgui.text("Assets:");
        imgui.spacing();

        // TODO: Replace with actual asset listing
        if (imgui.treeNode("shaders/")) {
            imgui.text("basic.vert.glsl");
            imgui.text("basic.frag.glsl");
            imgui.treePop();
        }
        if (imgui.treeNode("textures/")) {
            imgui.text("(empty)");
            imgui.treePop();
        }
        if (imgui.treeNode("materials/")) {
            imgui.text("(empty)");
            imgui.treePop();
        }
    }
    imgui.end();
}
