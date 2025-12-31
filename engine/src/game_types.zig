const std = @import("std");

pub const ApplicationConfig = struct {
    startPosX: i16,
    startPosY: i16,
    startWidth: i16,
    startHeight: i16,
    name: [:0]const u8,
};

pub const Game = struct {
    appConfig: ApplicationConfig,
    initialize: *const fn (*Game) bool,
    update: *const fn (*Game, f64) bool,
    render: *const fn (*Game, f64) bool,
    onResize: *const fn (*Game, u32, u32) void,
    shutdown: *const fn (*Game) void,
    state: ?*anyopaque,
    applicationState: ?*anyopaque,
};
