//! Command System
//! Defines the Command structure and callback types for the editor command system.

const std = @import("std");

/// Function signature for command callbacks.
/// The context parameter allows passing arbitrary data to the command.
pub const CommandFn = *const fn (context: ?*anyopaque) void;

/// A registered command in the editor system.
/// Commands can be invoked by keybindings or through the command palette.
pub const Command = struct {
    /// Unique identifier for the command (e.g., "view.toggle_console").
    /// Used for keybinding mappings and programmatic invocation.
    id: []const u8,

    /// Human-readable name displayed in the command palette.
    name: []const u8,

    /// Description shown in the command palette below the name.
    description: []const u8,

    /// Category for grouping commands (e.g., "View", "Edit", "File").
    category: []const u8,

    /// The callback function to execute when the command is invoked.
    callback: CommandFn,

    /// Optional context pointer passed to the callback.
    context: ?*anyopaque = null,

    /// Whether this command is currently enabled.
    /// Disabled commands are not shown in the palette and cannot be executed.
    enabled: bool = true,

    /// Format the command for display in the command palette.
    /// Returns: "Category: Name"
    pub fn formatDisplay(self: Command, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}: {s}", .{ self.category, self.name }) catch self.name;
    }
};
