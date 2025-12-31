const gameTypes = @import("game_types.zig");
const application = @import("core/application.zig");

// Re-export platform functionality for game to use
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
pub const imgui = @import("systems/imgui.zig");
pub const math = @import("math/math.zig");
pub const editor = @import("editor/editor.zig");
pub const resources = struct {
    pub const Texture = @import("resources/types.zig").Texture;
};

pub const Game = gameTypes.Game;
pub const ApplicationConfig = gameTypes.ApplicationConfig;

/// Implemented by the game library
extern fn createGame(outGame: *Game) bool;

pub fn main() !void {
    // Request the game instance from the application.
    var gameInstance: Game = undefined;

    if (!createGame(&gameInstance)) {
        logger.fatal("Could not create game!", .{});
        return error.CouldNotCreateGame;
    }

    if (!application.create(&gameInstance)) {
        logger.fatal("Application failed to create!", .{});
        return error.CouldNotCreateApplication;
    }

    // Begin the game loop.
    if (!application.run()) {
        logger.fatal("Application did not shutdown gracefully.", .{});
        return error.ApplicationFailedShutdown;
    }
}
