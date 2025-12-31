//! Keybinding Configuration
//! Handles loading keybindings from configuration files.

const std = @import("std");
const logger = @import("../../core/logging.zig");
const KeybindingManager = @import("manager.zig").KeybindingManager;
const keybinding = @import("keybinding.zig");
const KeyCombo = keybinding.KeyCombo;

/// Error types for config loading.
pub const ConfigError = error{
    FileNotFound,
    ReadFailed,
    ParseFailed,
    InvalidFormat,
    OutOfMemory,
};

/// Load keybindings from a simple text configuration file.
/// Format: one binding per line, "key_combo = command_id" or "key_combo = command_id when condition"
/// Lines starting with '#' or '//' are comments.
/// Empty lines are ignored.
///
/// Example:
/// ```
/// # Editor keybindings
/// Ctrl+P = editor.command_palette
/// Ctrl+C = view.toggle_console
/// T = gizmo.mode_translate when gizmo_visible
/// Escape = editor.close_palette when palette_open
/// ```
pub fn loadFromFile(manager: *KeybindingManager, path: []const u8) ConfigError!void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        logger.warn("Could not open keybindings config file '{s}': {}", .{ path, err });
        return ConfigError.FileNotFound;
    };
    defer file.close();

    const content = file.readToEndAlloc(manager.allocator, 1024 * 1024) catch {
        return ConfigError.ReadFailed;
    };
    defer manager.allocator.free(content);

    try parseAndRegister(manager, content);
}

/// Parse configuration content and register keybindings.
fn parseAndRegister(manager: *KeybindingManager, content: []const u8) ConfigError!void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;

    while (lines.next()) |line| {
        line_num += 1;

        // Trim whitespace
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;
        if (std.mem.startsWith(u8, trimmed, "//")) continue;

        // Parse the line
        parseLine(manager, trimmed) catch |err| {
            logger.warn("Invalid keybinding at line {}: {s} ({})", .{ line_num, trimmed, err });
            continue;
        };
    }
}

/// Parse a single keybinding line.
fn parseLine(manager: *KeybindingManager, line: []const u8) !void {
    // Find the '=' separator
    const eq_pos = std.mem.indexOf(u8, line, "=") orelse return error.InvalidFormat;

    const key_part = std.mem.trim(u8, line[0..eq_pos], " \t");
    var rest = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

    // Parse the key combo
    const combo = keybinding.parseKeyCombo(key_part) orelse return error.InvalidFormat;

    // Check for 'when' condition
    var command_id: []const u8 = rest;
    var when_condition: ?[]const u8 = null;

    if (std.mem.indexOf(u8, rest, " when ")) |when_pos| {
        command_id = std.mem.trim(u8, rest[0..when_pos], " \t");
        when_condition = std.mem.trim(u8, rest[when_pos + 6 ..], " \t");
    }

    // Register the binding
    if (when_condition) |when| {
        try manager.bindWhen(combo, command_id, when);
    } else {
        try manager.bind(combo, command_id);
    }
}

/// Save current keybindings to a configuration file.
pub fn saveToFile(manager: *KeybindingManager, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var writer = file.writer();

    try writer.writeAll("# Butter Engine Keybindings Configuration\n");
    try writer.writeAll("# Format: key_combo = command_id [when condition]\n");
    try writer.writeAll("# Examples:\n");
    try writer.writeAll("#   Ctrl+P = editor.command_palette\n");
    try writer.writeAll("#   T = gizmo.mode_translate when gizmo_visible\n");
    try writer.writeAll("\n");

    var buf: [64]u8 = undefined;
    for (manager.bindings.items) |binding| {
        const combo_str = binding.combo.format(&buf);

        if (binding.when) |when| {
            try writer.print("{s} = {s} when {s}\n", .{ combo_str, binding.command_id, when });
        } else {
            try writer.print("{s} = {s}\n", .{ combo_str, binding.command_id });
        }
    }

    logger.info("Saved keybindings to '{s}'", .{path});
}
