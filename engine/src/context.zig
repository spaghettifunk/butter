//! Centralized engine context for sharing subsystem state across library boundaries.
//!
//! This module solves the problem of Zig static libraries having separate copies
//! of module-level variables. By exporting a single context pointer, all subsystems
//! can share state through one well-defined mechanism.
//!
//! To add a new subsystem:
//! 1. Import the subsystem module here
//! 2. Add a field to EngineContext struct
//! 3. In your subsystem's initialize(), set context.get().yourSubsystem = &instance
//! 4. In your subsystem's shutdown(), set context.get().yourSubsystem = null

const std = @import("std");
const memory = @import("systems/memory.zig");
const event = @import("systems/event.zig");
const input = @import("systems/input.zig");
const logging = @import("core/logging.zig");
const texture = @import("systems/texture.zig");
const material = @import("systems/material.zig");
const geometry = @import("systems/geometry.zig");
const mesh_asset = @import("systems/mesh_asset.zig");
const renderer = @import("renderer/renderer.zig");
const jobs = @import("systems/jobs.zig");
const resource_manager = @import("resources/manager.zig");

const render_graph = @import("renderer/render_graph/mod.zig");

const CommandRegistry = @import("editor/commands/registry.zig").CommandRegistry;
const EditorScene = @import("editor/editor_scene.zig").EditorScene;

/// Central context containing pointers to all engine subsystems.
/// Note: platform uses opaque pointer to avoid GLFW dependency in game library
/// This is an extern struct to allow cross-library sharing via extern var
pub const EngineContext = extern struct {
    memory: ?*memory.MemorySystem,
    logging: ?*logging.LoggingSystem,
    event: ?*event.EventSystem,
    input: ?*input.InputSystem,
    texture: ?*texture.TextureSystem,
    material: ?*material.MaterialSystem,
    geometry: ?*geometry.GeometrySystem, // DEPRECATED: Use mesh_asset instead
    mesh_asset: ?*mesh_asset.MeshAssetSystem, // NEW: Replacement for geometry system
    renderer: ?*renderer.RendererSystem,

    render_graph: ?*render_graph.RenderGraph,

    jobs: ?*jobs.JobScheduler, // Job system for parallelization
    resource_manager: ?*resource_manager.ResourceManager, // Unified resource management

    platform_window: ?*anyopaque, // Opaque pointer to GLFW window
    command_registry: ?*CommandRegistry, // Editor command registry
    editor_scene: ?*EditorScene, // Editor scene (shared across library boundaries)
    // Add future subsystems here:
    // audio: ?*audio.AudioSystem,
};

// The actual storage - lives in the executable
var contextStorage: EngineContext = .{
    .memory = null,
    .logging = null,
    .event = null,
    .input = null,
    .texture = null,
    .material = null,
    .geometry = null,
    .mesh_asset = null,
    .renderer = null,

    .render_graph = null,

    .jobs = null,
    .resource_manager = null,

    .platform_window = null,
    .command_registry = null,
    .editor_scene = null,
};

// Extern declaration that will be resolved at link time
// This references the exported context storage
extern var _engineContext: EngineContext;

// Export the context storage when building any of the engine executables
// (runtime_main.zig or editor_main.zig), but not when used as a module in game library
comptime {
    const root = @import("root");
    const is_runtime_main = root == @import("runtime_main.zig");
    const is_editor_main = root == @import("editor_main.zig");
    const is_engine_main = root == @import("engine.zig"); // Legacy support
    if (is_runtime_main or is_editor_main or is_engine_main) {
        @export(&contextStorage, .{ .name = "_engineContext" });
    }
}

/// Get the shared engine context. Works from both engine and game.
pub fn get() *EngineContext {
    return &_engineContext;
}
