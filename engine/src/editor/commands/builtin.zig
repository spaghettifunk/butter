//! Built-in Commands
//! Provides the default set of editor commands.

const std = @import("std");
const Command = @import("command.zig").Command;
const CommandRegistry = @import("registry.zig").CommandRegistry;
const logger = @import("../../core/logging.zig");

/// Editor state callbacks - set by editor.zig during initialization.
pub const EditorCallbacks = struct {
    openCommandPalette: ?*const fn () void = null,
    closeCommandPalette: ?*const fn () void = null,
    toggleConsole: ?*const fn () void = null,
    toggleResourceLoading: ?*const fn () void = null,
    toggleAssetManager: ?*const fn () void = null,
    toggleMaterialPanel: ?*const fn () void = null,
    toggleSceneHierarchy: ?*const fn () void = null,
    togglePropertyInspector: ?*const fn () void = null,
    toggleDebugOverlay: ?*const fn () void = null,
    toggleGizmo: ?*const fn () void = null,
    gizmoModeTranslate: ?*const fn () void = null,
    gizmoModeRotate: ?*const fn () void = null,
    gizmoModeScale: ?*const fn () void = null,
    gizmoToggleSpace: ?*const fn () void = null,
    toggleGizmoPanel: ?*const fn () void = null,
    toggleLightPanel: ?*const fn () void = null,
};

var callbacks: EditorCallbacks = .{};

/// Set the editor callbacks. Called by editor.zig during initialization.
pub fn setCallbacks(cb: EditorCallbacks) void {
    callbacks = cb;
}

/// Register all built-in editor commands.
pub fn registerBuiltinCommands(registry: *CommandRegistry) !void {
    // Editor commands
    try registry.register(.{
        .id = "editor.command_palette",
        .name = "Command Palette",
        .description = "Open the command palette",
        .category = "Editor",
        .callback = cmdOpenCommandPalette,
    });

    try registry.register(.{
        .id = "editor.close_palette",
        .name = "Close Palette",
        .description = "Close the command palette",
        .category = "Editor",
        .callback = cmdCloseCommandPalette,
    });

    // View commands - Panel toggles
    try registry.register(.{
        .id = "view.toggle_console",
        .name = "Toggle Console",
        .description = "Show or hide the console panel",
        .category = "View",
        .callback = cmdToggleConsole,
    });

    try registry.register(.{
        .id = "view.toggle_resource_loading",
        .name = "Toggle Resource Loading",
        .description = "Show or hide the resource loading panel",
        .category = "View",
        .callback = cmdToggleResourceLoading,
    });

    try registry.register(.{
        .id = "view.toggle_asset_manager",
        .name = "Toggle Asset Manager",
        .description = "Show or hide the asset manager panel",
        .category = "View",
        .callback = cmdToggleAssetManager,
    });

    try registry.register(.{
        .id = "view.toggle_material_panel",
        .name = "Toggle Material Panel",
        .description = "Show or hide the material panel",
        .category = "View",
        .callback = cmdToggleMaterialPanel,
    });

    try registry.register(.{
        .id = "view.toggle_scene_hierarchy",
        .name = "Toggle Scene Hierarchy",
        .description = "Show or hide the scene hierarchy panel",
        .category = "View",
        .callback = cmdToggleSceneHierarchy,
    });

    try registry.register(.{
        .id = "view.toggle_property_inspector",
        .name = "Toggle Property Inspector",
        .description = "Show or hide the property inspector panel",
        .category = "View",
        .callback = cmdTogglePropertyInspector,
    });

    try registry.register(.{
        .id = "view.toggle_debug_overlay",
        .name = "Toggle Debug Overlay",
        .description = "Show or hide FPS and debug information",
        .category = "View",
        .callback = cmdToggleDebugOverlay,
    });

    try registry.register(.{
        .id = "view.toggle_gizmo",
        .name = "Toggle Gizmo",
        .description = "Show or hide the transform gizmo",
        .category = "View",
        .callback = cmdToggleGizmo,
    });

    try registry.register(.{
        .id = "view.toggle_gizmo_panel",
        .name = "Toggle Gizmo Panel",
        .description = "Show or hide the gizmo transform panel",
        .category = "View",
        .callback = cmdToggleGizmoPanel,
    });

    try registry.register(.{
        .id = "view.toggle_light_panel",
        .name = "Toggle Light Panel",
        .description = "Show or hide the light editor panel",
        .category = "View",
        .callback = cmdToggleLightPanel,
    });

    // Gizmo commands
    try registry.register(.{
        .id = "gizmo.mode_translate",
        .name = "Translate Mode",
        .description = "Switch gizmo to translate mode",
        .category = "Gizmo",
        .callback = cmdGizmoModeTranslate,
    });

    try registry.register(.{
        .id = "gizmo.mode_rotate",
        .name = "Rotate Mode",
        .description = "Switch gizmo to rotate mode",
        .category = "Gizmo",
        .callback = cmdGizmoModeRotate,
    });

    try registry.register(.{
        .id = "gizmo.mode_scale",
        .name = "Scale Mode",
        .description = "Switch gizmo to scale mode",
        .category = "Gizmo",
        .callback = cmdGizmoModeScale,
    });

    try registry.register(.{
        .id = "gizmo.toggle_space",
        .name = "Toggle Local/World Space",
        .description = "Switch between local and world coordinate space",
        .category = "Gizmo",
        .callback = cmdGizmoToggleSpace,
    });

    logger.info("Registered {} built-in commands", .{registry.count()});
}

// Command callback implementations

fn cmdOpenCommandPalette(_: ?*anyopaque) void {
    if (callbacks.openCommandPalette) |cb| cb();
}

fn cmdCloseCommandPalette(_: ?*anyopaque) void {
    if (callbacks.closeCommandPalette) |cb| cb();
}

fn cmdToggleConsole(_: ?*anyopaque) void {
    if (callbacks.toggleConsole) |cb| cb();
}

fn cmdToggleResourceLoading(_: ?*anyopaque) void {
    if (callbacks.toggleResourceLoading) |cb| cb();
}

fn cmdToggleAssetManager(_: ?*anyopaque) void {
    if (callbacks.toggleAssetManager) |cb| cb();
}

fn cmdToggleMaterialPanel(_: ?*anyopaque) void {
    if (callbacks.toggleMaterialPanel) |cb| cb();
}

fn cmdToggleSceneHierarchy(_: ?*anyopaque) void {
    if (callbacks.toggleSceneHierarchy) |cb| cb();
}

fn cmdTogglePropertyInspector(_: ?*anyopaque) void {
    if (callbacks.togglePropertyInspector) |cb| cb();
}

fn cmdToggleDebugOverlay(_: ?*anyopaque) void {
    if (callbacks.toggleDebugOverlay) |cb| cb();
}

fn cmdToggleGizmo(_: ?*anyopaque) void {
    if (callbacks.toggleGizmo) |cb| cb();
}

fn cmdGizmoModeTranslate(_: ?*anyopaque) void {
    if (callbacks.gizmoModeTranslate) |cb| cb();
}

fn cmdGizmoModeRotate(_: ?*anyopaque) void {
    if (callbacks.gizmoModeRotate) |cb| cb();
}

fn cmdGizmoModeScale(_: ?*anyopaque) void {
    if (callbacks.gizmoModeScale) |cb| cb();
}

fn cmdGizmoToggleSpace(_: ?*anyopaque) void {
    if (callbacks.gizmoToggleSpace) |cb| cb();
}

fn cmdToggleGizmoPanel(_: ?*anyopaque) void {
    if (callbacks.toggleGizmoPanel) |cb| cb();
}

fn cmdToggleLightPanel(_: ?*anyopaque) void {
    if (callbacks.toggleLightPanel) |cb| cb();
}
