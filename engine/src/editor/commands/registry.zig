//! Command Registry
//! Stores and manages all registered commands in the editor.

const std = @import("std");
const Command = @import("command.zig").Command;
const logger = @import("../../core/logging.zig");

pub const CommandRegistry = struct {
    allocator: std.mem.Allocator,
    commands: std.StringHashMap(Command),

    /// Initialize a new command registry.
    pub fn init(allocator: std.mem.Allocator) CommandRegistry {
        return .{
            .allocator = allocator,
            .commands = std.StringHashMap(Command).init(allocator),
        };
    }

    /// Shutdown and free all resources.
    pub fn deinit(self: *CommandRegistry) void {
        self.commands.deinit();
    }

    /// Register a new command.
    /// If a command with the same ID already exists, it will be replaced.
    pub fn register(self: *CommandRegistry, cmd: Command) !void {
        try self.commands.put(cmd.id, cmd);
        logger.debug("Registered command: {s}", .{cmd.id});
    }

    /// Unregister a command by ID.
    /// Returns true if the command was found and removed.
    pub fn unregister(self: *CommandRegistry, id: []const u8) bool {
        return self.commands.remove(id);
    }

    /// Get a command by ID.
    /// Returns null if the command is not found.
    pub fn get(self: *CommandRegistry, id: []const u8) ?Command {
        return self.commands.get(id);
    }

    /// Execute a command by ID.
    /// Returns true if the command was found and executed.
    pub fn execute(self: *CommandRegistry, id: []const u8) bool {
        if (self.commands.get(id)) |cmd| {
            if (cmd.enabled) {
                cmd.callback(cmd.context);
                logger.debug("Executed command: {s}", .{cmd.id});
                return true;
            }
            logger.debug("Command disabled: {s}", .{cmd.id});
        }
        return false;
    }

    /// Get the total number of registered commands.
    pub fn count(self: *CommandRegistry) usize {
        return self.commands.count();
    }

    /// Iterator for iterating over all commands.
    pub fn iterator(self: *CommandRegistry) std.StringHashMap(Command).Iterator {
        return self.commands.iterator();
    }

    /// Check if a command with the given ID exists.
    pub fn contains(self: *CommandRegistry, id: []const u8) bool {
        return self.commands.contains(id);
    }

    /// Enable or disable a command.
    pub fn setEnabled(self: *CommandRegistry, id: []const u8, enabled: bool) bool {
        if (self.commands.getPtr(id)) |cmd| {
            cmd.enabled = enabled;
            return true;
        }
        return false;
    }
};
