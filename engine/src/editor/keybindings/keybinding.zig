//! Keybinding Types
//! Defines KeyCombo and KeybindingEntry structures for the keybinding system.

const std = @import("std");
const input = @import("../../systems/input.zig");

/// Represents a key combination (key + modifiers).
pub const KeyCombo = struct {
    key: input.Key,
    mods: Modifiers,

    /// Modifier flags for key combinations.
    pub const Modifiers = struct {
        ctrl: bool = false,
        shift: bool = false,
        alt: bool = false,
        super: bool = false,
    };

    /// Create a KeyCombo from a key and modifier flags.
    pub fn create(k: input.Key, ctrl_mod: bool, shift_mod: bool, alt_mod: bool, super_mod: bool) KeyCombo {
        return .{
            .key = k,
            .mods = .{
                .ctrl = ctrl_mod,
                .shift = shift_mod,
                .alt = alt_mod,
                .super = super_mod,
            },
        };
    }

    /// Create a KeyCombo with no modifiers.
    pub fn noMod(k: input.Key) KeyCombo {
        return .{
            .key = k,
            .mods = .{},
        };
    }

    /// Create a KeyCombo with Ctrl modifier.
    pub fn ctrl(k: input.Key) KeyCombo {
        return create(k, true, false, false, false);
    }

    /// Create a KeyCombo with Ctrl+Shift modifiers.
    pub fn ctrlShift(k: input.Key) KeyCombo {
        return create(k, true, true, false, false);
    }

    /// Check if this combo matches the given key and modifiers from the input system.
    pub fn matches(self: KeyCombo, k: input.Key, input_mods: input.Mods) bool {
        return self.key == k and
            self.mods.ctrl == input_mods.control and
            self.mods.shift == input_mods.shift and
            self.mods.alt == input_mods.alt and
            self.mods.super == input_mods.super;
    }

    /// Format the key combo as a human-readable string (e.g., "Ctrl+Shift+P").
    pub fn format(self: KeyCombo, buf: []u8) []const u8 {
        var offset: usize = 0;

        if (self.mods.ctrl) {
            const ctrl_str = "Ctrl+";
            if (offset + ctrl_str.len <= buf.len) {
                @memcpy(buf[offset..][0..ctrl_str.len], ctrl_str);
                offset += ctrl_str.len;
            }
        }
        if (self.mods.shift) {
            const shift_str = "Shift+";
            if (offset + shift_str.len <= buf.len) {
                @memcpy(buf[offset..][0..shift_str.len], shift_str);
                offset += shift_str.len;
            }
        }
        if (self.mods.alt) {
            const alt_str = "Alt+";
            if (offset + alt_str.len <= buf.len) {
                @memcpy(buf[offset..][0..alt_str.len], alt_str);
                offset += alt_str.len;
            }
        }
        if (self.mods.super) {
            const super_str = "Super+";
            if (offset + super_str.len <= buf.len) {
                @memcpy(buf[offset..][0..super_str.len], super_str);
                offset += super_str.len;
            }
        }

        // Add key name
        const key_name = keyToString(self.key);
        if (offset + key_name.len <= buf.len) {
            @memcpy(buf[offset..][0..key_name.len], key_name);
            offset += key_name.len;
        }

        return buf[0..offset];
    }
};

/// A keybinding entry mapping a key combo to a command.
pub const KeybindingEntry = struct {
    /// The key combination that triggers this binding.
    combo: KeyCombo,
    /// The command ID to execute (e.g., "view.toggle_console").
    command_id: []const u8,
    /// Optional condition for when this binding is active.
    /// Examples: "palette_open", "gizmo_visible", "!editing_text"
    when: ?[]const u8 = null,
};

/// Convert a Key enum value to its string representation.
pub fn keyToString(k: input.Key) []const u8 {
    return switch (k) {
        .a => "A",
        .b => "B",
        .c => "C",
        .d => "D",
        .e => "E",
        .f => "F",
        .g => "G",
        .h => "H",
        .i => "I",
        .j => "J",
        .k => "K",
        .l => "L",
        .m => "M",
        .n => "N",
        .o => "O",
        .p => "P",
        .q => "Q",
        .r => "R",
        .s => "S",
        .t => "T",
        .u => "U",
        .v => "V",
        .w => "W",
        .x => "X",
        .y => "Y",
        .z => "Z",
        .@"0" => "0",
        .@"1" => "1",
        .@"2" => "2",
        .@"3" => "3",
        .@"4" => "4",
        .@"5" => "5",
        .@"6" => "6",
        .@"7" => "7",
        .@"8" => "8",
        .@"9" => "9",
        .escape => "Escape",
        .enter => "Enter",
        .space => "Space",
        .tab => "Tab",
        .backspace => "Backspace",
        .delete => "Delete",
        .insert => "Insert",
        .home => "Home",
        .end => "End",
        .page_up => "PageUp",
        .page_down => "PageDown",
        .up => "Up",
        .down => "Down",
        .left => "Left",
        .right => "Right",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
        .minus => "-",
        .equal => "=",
        .left_bracket => "[",
        .right_bracket => "]",
        .backslash => "\\",
        .semicolon => ";",
        .apostrophe => "'",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .grave_accent => "`",
        else => "?",
    };
}

/// Parse a key string (e.g., "A", "Escape", "F1") to a Key enum value.
pub fn stringToKey(s: []const u8) ?input.Key {
    // Single character keys (A-Z, 0-9)
    if (s.len == 1) {
        const c = std.ascii.toUpper(s[0]);
        if (c >= 'A' and c <= 'Z') {
            return @enumFromInt(c);
        }
        if (c >= '0' and c <= '9') {
            return @enumFromInt(c);
        }
    }

    // Named keys (case-insensitive comparison)
    const lower = blk: {
        var buf: [32]u8 = undefined;
        const len = @min(s.len, buf.len);
        for (s[0..len], 0..) |c, i| {
            buf[i] = std.ascii.toLower(c);
        }
        break :blk buf[0..len];
    };

    if (std.mem.eql(u8, lower, "escape") or std.mem.eql(u8, lower, "esc")) return .escape;
    if (std.mem.eql(u8, lower, "enter") or std.mem.eql(u8, lower, "return")) return .enter;
    if (std.mem.eql(u8, lower, "space")) return .space;
    if (std.mem.eql(u8, lower, "tab")) return .tab;
    if (std.mem.eql(u8, lower, "backspace")) return .backspace;
    if (std.mem.eql(u8, lower, "delete") or std.mem.eql(u8, lower, "del")) return .delete;
    if (std.mem.eql(u8, lower, "insert") or std.mem.eql(u8, lower, "ins")) return .insert;
    if (std.mem.eql(u8, lower, "home")) return .home;
    if (std.mem.eql(u8, lower, "end")) return .end;
    if (std.mem.eql(u8, lower, "pageup") or std.mem.eql(u8, lower, "pgup")) return .page_up;
    if (std.mem.eql(u8, lower, "pagedown") or std.mem.eql(u8, lower, "pgdn")) return .page_down;
    if (std.mem.eql(u8, lower, "up")) return .up;
    if (std.mem.eql(u8, lower, "down")) return .down;
    if (std.mem.eql(u8, lower, "left")) return .left;
    if (std.mem.eql(u8, lower, "right")) return .right;
    if (std.mem.eql(u8, lower, "f1")) return .f1;
    if (std.mem.eql(u8, lower, "f2")) return .f2;
    if (std.mem.eql(u8, lower, "f3")) return .f3;
    if (std.mem.eql(u8, lower, "f4")) return .f4;
    if (std.mem.eql(u8, lower, "f5")) return .f5;
    if (std.mem.eql(u8, lower, "f6")) return .f6;
    if (std.mem.eql(u8, lower, "f7")) return .f7;
    if (std.mem.eql(u8, lower, "f8")) return .f8;
    if (std.mem.eql(u8, lower, "f9")) return .f9;
    if (std.mem.eql(u8, lower, "f10")) return .f10;
    if (std.mem.eql(u8, lower, "f11")) return .f11;
    if (std.mem.eql(u8, lower, "f12")) return .f12;

    return null;
}

/// Parse a key combo string (e.g., "Ctrl+Shift+P") to a KeyCombo.
pub fn parseKeyCombo(s: []const u8) ?KeyCombo {
    var ctrl = false;
    var shift = false;
    var alt = false;
    var super = false;
    var key_value: ?input.Key = null;

    var iter = std.mem.splitSequence(u8, s, "+");
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len == 0) continue;

        // Check for modifier keywords
        const lower = blk: {
            var buf: [16]u8 = undefined;
            const len = @min(trimmed.len, buf.len);
            for (trimmed[0..len], 0..) |c, i| {
                buf[i] = std.ascii.toLower(c);
            }
            break :blk buf[0..len];
        };

        if (std.mem.eql(u8, lower, "ctrl") or std.mem.eql(u8, lower, "control")) {
            ctrl = true;
        } else if (std.mem.eql(u8, lower, "shift")) {
            shift = true;
        } else if (std.mem.eql(u8, lower, "alt")) {
            alt = true;
        } else if (std.mem.eql(u8, lower, "super") or std.mem.eql(u8, lower, "cmd") or std.mem.eql(u8, lower, "win")) {
            super = true;
        } else {
            // Must be the key itself
            key_value = stringToKey(trimmed);
        }
    }

    if (key_value) |k| {
        return KeyCombo.create(k, ctrl, shift, alt, super);
    }

    return null;
}
