//! Editor Entry Point
//! Full-featured development executable with ImGui, validation, and editor UI.

const std = @import("std");
const engine = @import("engine_lib.zig");
const application = @import("core/application.zig");
const build_options = @import("build_options");

/// Implemented by the game library
extern fn createGame(outGame: *engine.Game) bool;

pub fn main() !void {
    // Request the game instance from the application.
    var gameInstance: engine.Game = undefined;

    if (!createGame(&gameInstance)) {
        engine.logger.fatal("Could not create game!", .{});
        return error.CouldNotCreateGame;
    }

    // Create application in editor mode (with ImGui and editor features)
    if (!application.createEditor(&gameInstance)) {
        engine.logger.fatal("Editor failed to create!", .{});
        return error.CouldNotCreateEditor;
    }

    // Initialize editor systems (after application is created)
    if (build_options.enable_editor) {
        if (!engine.editor.EditorSystem.initialize()) {
            engine.logger.warn("Editor UI failed to initialize - running in limited mode", .{});
        }
    }

    // Begin the game loop.
    if (!application.run()) {
        engine.logger.fatal("Application did not shutdown gracefully.", .{});
        return error.ApplicationFailedShutdown;
    }

    // Shutdown editor systems
    if (build_options.enable_editor) {
        engine.editor.EditorSystem.shutdown();
    }
}
