//! Runtime Entry Point
//! Minimal game executable for shipping - no editor features, no ImGui.

const std = @import("std");
const engine = @import("engine_lib.zig");
const application = @import("core/application.zig");

/// Implemented by the game library
extern fn createGame(outGame: *engine.Game) bool;

pub fn main() !void {
    // Request the game instance from the application.
    var gameInstance: engine.Game = undefined;

    if (!createGame(&gameInstance)) {
        engine.logger.fatal("Could not create game!", .{});
        return error.CouldNotCreateGame;
    }

    // Create application in runtime mode (no ImGui, no editor)
    if (!application.createRuntime(&gameInstance)) {
        engine.logger.fatal("Application failed to create!", .{});
        return error.CouldNotCreateApplication;
    }

    // Begin the game loop.
    if (!application.run()) {
        engine.logger.fatal("Application did not shutdown gracefully.", .{});
        return error.ApplicationFailedShutdown;
    }
}
