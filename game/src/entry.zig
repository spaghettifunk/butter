const std = @import("std");
const engine = @import("engine");
const Game = engine.Game;
const game = @import("game.zig");

pub export fn createGame(outGame: *Game) bool {
    outGame.appConfig = .{
        .startPosX = 100,
        .startPosY = 100,
        .startWidth = 1280,
        .startHeight = 720,
        .name = "Butter Game",
    };

    outGame.initialize = game.callbacks.initialize;
    outGame.update = game.callbacks.update;
    outGame.render = game.callbacks.render;
    outGame.onResize = game.callbacks.onResize;
    outGame.shutdown = game.callbacks.shutdown;

    const gameState = engine.memory.allocate(game.GameState, .game) orelse return false;
    gameState.* = .{
        .deltaTime = 0.16,
    };
    outGame.state = gameState;
    outGame.applicationState = null;

    return true;
}
