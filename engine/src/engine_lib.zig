//! Engine Library Module
//! Re-exports all engine subsystems for game use.
//! This module uses build_options to conditionally export features.

const build_options = @import("build_options");
const gameTypes = @import("game_types.zig");

// Debug: export build options status for runtime verification
pub const editor_enabled = build_options.enable_editor;
pub const imgui_enabled = build_options.enable_imgui;

// Core exports (always available)
pub const platform = @import("platform/platform.zig");
pub const logger = @import("core/logging.zig");
pub const memory = @import("systems/memory.zig");
pub const renderer = @import("renderer/renderer.zig");
pub const render_graph = @import("systems/render_graph.zig");
pub const render_graph_types = @import("renderer/render_graph/mod.zig");
pub const input = @import("systems/input.zig");
pub const texture = @import("systems/texture.zig");
pub const material = @import("systems/material.zig");
pub const geometry = @import("systems/geometry.zig");
pub const math = @import("math/math.zig");
pub const resources = struct {
    pub const Texture = @import("resources/types.zig").Texture;
};

// Export resource handles
pub const resource_handle = @import("resources/handle.zig");

// Export context for debugging and shared state access
pub const context = @import("context.zig");

// Game types
pub const Game = gameTypes.Game;
pub const ApplicationConfig = gameTypes.ApplicationConfig;

// Conditional ImGui export - uses stub when ImGui is disabled
pub const imgui = if (build_options.enable_imgui)
    @import("systems/imgui.zig")
else
    @import("systems/imgui_stub.zig");

// Editor scene types - always available for game code to use
pub const editor_scene = @import("editor/editor_scene.zig");
pub const Transform = editor_scene.Transform;
pub const EditorObject = editor_scene.EditorObject;
pub const EditorScene = editor_scene.EditorScene;

// Conditional editor UI export - empty struct when editor is disabled
pub const editor = if (build_options.enable_editor)
    @import("editor/editor.zig")
else
    struct {
        pub const EditorSystem = struct {
            pub fn initialize() bool {
                return true;
            }
            pub fn shutdown() void {}
            pub fn update(_: f32) void {}
            pub fn updateCamera(_: f32) void {}

            // Runtime scene - shared between editor and game
            var runtime_scene: ?*EditorScene = null;

            pub fn getEditorScene() ?*EditorScene {
                // This will be set by the real editor when enabled
                // For runtime-only builds, we create a simple scene
                if (runtime_scene == null) {
                    const allocator = @import("systems/memory.zig").getAllocator();
                    const scene_ptr = allocator.create(EditorScene) catch return undefined;
                    scene_ptr.* = EditorScene.init(allocator);
                    runtime_scene = scene_ptr;
                }
                return runtime_scene.?;
            }
        };
    };
