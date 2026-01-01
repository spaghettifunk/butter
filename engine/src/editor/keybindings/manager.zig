//! Keybinding Manager
//! Manages keybindings and dispatches commands based on key events.

const std = @import("std");
const input = @import("../../systems/input.zig");
const imgui = @import("../../systems/imgui.zig");
const logger = @import("../../core/logging.zig");
const KeyCombo = @import("keybinding.zig").KeyCombo;
const KeybindingEntry = @import("keybinding.zig").KeybindingEntry;
const CommandRegistry = @import("../commands/registry.zig").CommandRegistry;

/// Context state for conditional keybindings.
pub const KeybindingContext = struct {
    /// Whether the command palette is currently open.
    command_palette_open: bool = false,
    /// Whether the user is editing text in an ImGui input field.
    editing_text: bool = false,
    /// Whether the gizmo is currently visible.
    gizmo_visible: bool = false,
};

pub const KeybindingManager = struct {
    allocator: std.mem.Allocator,
    bindings: std.ArrayList(KeybindingEntry),
    command_registry: *CommandRegistry,
    context: KeybindingContext,

    /// Initialize a new keybinding manager.
    pub fn init(allocator: std.mem.Allocator, registry: *CommandRegistry) KeybindingManager {
        return .{
            .allocator = allocator,
            .bindings = .empty,
            .command_registry = registry,
            .context = .{},
        };
    }

    /// Shutdown and free all resources.
    pub fn deinit(self: *KeybindingManager) void {
        self.bindings.deinit(self.allocator);
    }

    /// Add a keybinding without a condition.
    pub fn bind(self: *KeybindingManager, combo: KeyCombo, command_id: []const u8) !void {
        try self.bindings.append(self.allocator, .{
            .combo = combo,
            .command_id = command_id,
            .when = null,
        });
    }

    /// Add a keybinding with a condition.
    pub fn bindWhen(self: *KeybindingManager, combo: KeyCombo, command_id: []const u8, when: []const u8) !void {
        try self.bindings.append(self.allocator, .{
            .combo = combo,
            .command_id = command_id,
            .when = when,
        });
    }

    /// Remove all bindings for a specific command.
    pub fn unbind(self: *KeybindingManager, command_id: []const u8) void {
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            if (std.mem.eql(u8, self.bindings.items[i].command_id, command_id)) {
                _ = self.bindings.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Remove a specific keybinding.
    pub fn unbindCombo(self: *KeybindingManager, combo: KeyCombo) void {
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            const binding = self.bindings.items[i];
            if (binding.combo.key == combo.key and
                binding.combo.mods.ctrl == combo.mods.ctrl and
                binding.combo.mods.shift == combo.mods.shift and
                binding.combo.mods.alt == combo.mods.alt and
                binding.combo.mods.super == combo.mods.super)
            {
                _ = self.bindings.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Process a key event and execute matching command.
    /// Returns true if a command was executed.
    pub fn processKeyEvent(self: *KeybindingManager, key: input.Key, mods: input.Mods) bool {
        // If ImGui wants keyboard input, we generally block global keybindings.
        if (imgui.ImGuiSystem.wantsCaptureKeyboard()) {
            // EXCEPTION: Always allow Escape to pass through if the command palette is open,
            // so it can be handled by the close_palette command.
            if (key == .escape and self.context.command_palette_open) {
                // Continue to process bindings
            } else {
                // For everything else, block keybindings while typing in ImGui fields
                return false;
            }
        }

        for (self.bindings.items) |binding| {
            if (binding.combo.matches(key, mods)) {
                // Check condition if present
                if (binding.when) |when| {
                    if (!self.checkCondition(when)) {
                        continue;
                    }
                }

                // Execute the command
                if (self.command_registry.execute(binding.command_id)) {
                    return true; // Event handled
                }
            }
        }

        return false;
    }

    /// Check if a condition string evaluates to true.
    fn checkCondition(self: *KeybindingManager, condition_raw: []const u8) bool {
        const condition = std.mem.trim(u8, condition_raw, " \t\r\n");

        // Empty condition always passes
        if (condition.len == 0) {
            return true;
        }

        // Handle negation prefix
        if (condition[0] == '!') {
            return !self.checkCondition(condition[1..]);
        }

        // Check known conditions
        if (std.mem.eql(u8, condition, "palette_open") or std.mem.eql(u8, condition, "command_palette_open")) {
            return self.context.command_palette_open;
        }
        if (std.mem.eql(u8, condition, "editing_text")) {
            return self.context.editing_text;
        }
        if (std.mem.eql(u8, condition, "gizmo_visible")) {
            return self.context.gizmo_visible;
        }

        // Unknown conditions pass by default
        logger.warn("Unknown keybinding condition: {s}", .{condition});
        return true;
    }

    /// Register the default keybindings.
    pub fn registerDefaults(self: *KeybindingManager) !void {
        // Command palette: Ctrl+P
        try self.bind(KeyCombo.ctrl(.p), "editor.command_palette");

        // Panel toggles
        try self.bind(KeyCombo.ctrl(.c), "view.toggle_console");
        try self.bind(KeyCombo.ctrl(.a), "view.toggle_asset_manager");
        try self.bind(KeyCombo.ctrl(.m), "view.toggle_material_panel");
        try self.bind(KeyCombo.ctrl(.d), "view.toggle_debug_overlay");
        try self.bind(KeyCombo.ctrl(.g), "view.toggle_gizmo");
        try self.bind(KeyCombo.ctrl(.l), "view.toggle_light_panel");
        try self.bind(KeyCombo.ctrlShift(.g), "view.toggle_gizmo_panel");

        // Gizmo modes (only when gizmo is visible)
        try self.bindWhen(KeyCombo.noMod(.t), "gizmo.mode_translate", "gizmo_visible");
        try self.bindWhen(KeyCombo.noMod(.r), "gizmo.mode_rotate", "gizmo_visible");
        try self.bindWhen(KeyCombo.noMod(.s), "gizmo.mode_scale", "gizmo_visible");
        try self.bindWhen(KeyCombo.noMod(.x), "gizmo.toggle_space", "gizmo_visible");

        // Escape closes command palette (only when open)
        try self.bindWhen(KeyCombo.noMod(.escape), "editor.close_palette", "palette_open");

        logger.info("Registered default keybindings", .{});
    }

    /// Get the number of registered keybindings.
    pub fn count(self: *KeybindingManager) usize {
        return self.bindings.items.len;
    }

    /// Find the keybinding for a command (returns the first match).
    pub fn getBindingForCommand(self: *KeybindingManager, command_id: []const u8) ?KeyCombo {
        for (self.bindings.items) |binding| {
            if (std.mem.eql(u8, binding.command_id, command_id)) {
                return binding.combo;
            }
        }
        return null;
    }
};
