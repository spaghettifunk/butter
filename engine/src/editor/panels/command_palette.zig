//! Command Palette
//! A modal popup for fuzzy-searching and executing commands.

const std = @import("std");
const imgui = @import("../../systems/imgui.zig");
const Command = @import("../commands/command.zig").Command;
const CommandRegistry = @import("../commands/registry.zig").CommandRegistry;
const fuzzy = @import("../fuzzy.zig");

const c = imgui.c;

/// Maximum number of filtered results to display.
const max_results = 20;

/// A filtered command with its match score.
const FilteredCommand = struct {
    command: Command,
    match: fuzzy.FuzzyMatch,
};

pub const CommandPalette = struct {
    allocator: std.mem.Allocator,

    /// Whether the palette is currently open.
    is_open: bool = false,

    /// Search input buffer.
    search_buffer: [256]u8 = [_]u8{0} ** 256,

    /// Length of the current search query.
    search_len: usize = 0,

    /// Currently selected result index.
    selected_index: usize = 0,

    /// Filtered command results.
    filtered_commands: std.ArrayList(FilteredCommand),

    /// Flag to focus input on next frame.
    just_opened: bool = false,

    /// Initialize the command palette.
    pub fn init(allocator: std.mem.Allocator) CommandPalette {
        return .{
            .allocator = allocator,
            .filtered_commands = .empty, //try std.ArrayList(FilteredCommand).initCapacity(allocator, 64),
        };
    }

    /// Shutdown and free resources.
    pub fn deinit(self: *CommandPalette) void {
        self.filtered_commands.deinit(self.allocator);
    }

    /// Open the command palette.
    pub fn open(self: *CommandPalette) void {
        self.is_open = true;
        self.just_opened = true;
        self.search_buffer = [_]u8{0} ** 256;
        self.search_len = 0;
        self.selected_index = 0;
        self.filtered_commands.clearRetainingCapacity();
    }

    /// Close the command palette.
    pub fn close(self: *CommandPalette) void {
        self.is_open = false;
    }

    /// Render the command palette.
    /// Returns the command ID to execute, or null if none selected.
    pub fn render(self: *CommandPalette, registry: *CommandRegistry) ?[]const u8 {
        if (!self.is_open) return null;

        var executed_command: ?[]const u8 = null;

        // Get display size for centering
        const io = imgui.getIO();
        const display_size = io.*.DisplaySize;
        const palette_width: f32 = 600;
        const palette_height: f32 = 400;

        // Center the palette on screen
        imgui.setNextWindowPos(.{
            .x = (display_size.x - palette_width) / 2,
            .y = display_size.y * 0.15,
        }, imgui.Cond.Always);
        imgui.setNextWindowSize(.{ .x = palette_width, .y = palette_height }, imgui.Cond.Always);

        // Window flags for modal-like behavior
        const flags = imgui.WindowFlags.NoTitleBar |
            imgui.WindowFlags.NoResize |
            imgui.WindowFlags.NoMove |
            imgui.WindowFlags.NoScrollbar;

        if (imgui.begin("##CommandPalette", null, flags)) {
            // Title
            imgui.text("Command Palette");
            imgui.separator();

            // Search input
            imgui.pushItemWidth(-1);

            if (self.just_opened) {
                imgui.setKeyboardFocusHere();
                self.just_opened = false;
            }

            const input_flags = imgui.InputTextFlags.EnterReturnsTrue |
                imgui.InputTextFlags.AutoSelectAll;

            const content_changed = imgui.inputTextWithHint(
                "##search",
                "Type to search commands...",
                &self.search_buffer,
                self.search_buffer.len,
                input_flags,
            );

            imgui.popItemWidth();

            // Handle Enter key - use explicit check to avoid premature execution on every change
            if (content_changed and imgui.isKeyPressed(.enter)) {
                if (self.filtered_commands.items.len > 0 and self.selected_index < self.filtered_commands.items.len) {
                    executed_command = self.filtered_commands.items[self.selected_index].command.id;
                    self.close();
                }
            }

            // Update search length
            self.search_len = std.mem.indexOfScalar(u8, &self.search_buffer, 0) orelse self.search_buffer.len;

            // Filter commands based on search
            self.filterCommands(registry);

            // Handle keyboard navigation using ImGui keys
            if (imgui.isKeyPressed(.up_arrow)) {
                if (self.selected_index > 0) {
                    self.selected_index -= 1;
                }
            }
            if (imgui.isKeyPressed(.down_arrow)) {
                if (self.selected_index + 1 < self.filtered_commands.items.len) {
                    self.selected_index += 1;
                }
            }
            if (imgui.isKeyPressed(.escape)) {
                self.close();
            }

            // Results list
            imgui.separator();

            // Scrollable child region for results
            if (imgui.beginChild("##results", .{ .x = 0, .y = 0 }, imgui.ChildFlags.None, imgui.WindowFlags.None)) {
                if (self.filtered_commands.items.len == 0) {
                    imgui.textDisabled("No matching commands");
                } else {
                    for (self.filtered_commands.items, 0..) |fc, i| {
                        const is_selected = (i == self.selected_index);

                        // Selectable item with custom rendering
                        imgui.pushIdInt(@intCast(i));

                        if (imgui.selectableEx("##item", is_selected, imgui.SelectableFlags.AllowDoubleClick, .{ .x = 0, .y = 40 })) {
                            executed_command = fc.command.id;
                            self.close();
                        }

                        // Custom rendering on same line
                        imgui.sameLine();
                        imgui.setCursorPosX(10);

                        // Command name (with category)
                        var name_buf: [128]u8 = undefined;
                        if (std.fmt.bufPrintZ(&name_buf, "{s}: {s}", .{ fc.command.category, fc.command.name })) |display_name| {
                            imgui.text(display_name.ptr);
                        } else |_| {
                            imgui.text(@ptrCast(fc.command.name.ptr));
                        }

                        // Description (dimmed, below)
                        imgui.setCursorPosX(10);
                        imgui.textDisabled(@ptrCast(fc.command.description.ptr));

                        imgui.popId();
                    }
                }
            }
            imgui.endChild();
        }
        imgui.end();

        return executed_command;
    }

    /// Filter commands based on the current search query.
    fn filterCommands(self: *CommandPalette, registry: *CommandRegistry) void {
        self.filtered_commands.clearRetainingCapacity();

        const query = self.search_buffer[0..self.search_len];

        var iter = registry.iterator();
        while (iter.next()) |entry| {
            const cmd = entry.value_ptr.*;

            if (!cmd.enabled) continue;

            // Match against name
            if (fuzzy.fuzzyMatch(query, cmd.name)) |match| {
                self.filtered_commands.append(self.allocator, .{
                    .command = cmd,
                    .match = match,
                }) catch continue;
            } else if (query.len == 0) {
                // Show all commands when query is empty
                self.filtered_commands.append(self.allocator, .{
                    .command = cmd,
                    .match = .{ .score = 0, .positions = undefined, .position_count = 0 },
                }) catch continue;
            }
        }

        // Sort by score (descending)
        if (self.filtered_commands.items.len > 0) {
            std.mem.sort(FilteredCommand, self.filtered_commands.items, {}, struct {
                fn lessThan(_: void, a: FilteredCommand, b: FilteredCommand) bool {
                    return a.match.score > b.match.score;
                }
            }.lessThan);
        }

        // Limit results
        if (self.filtered_commands.items.len > max_results) {
            self.filtered_commands.shrinkRetainingCapacity(max_results);
        }

        // Clamp selection index
        if (self.selected_index >= self.filtered_commands.items.len and self.filtered_commands.items.len > 0) {
            self.selected_index = self.filtered_commands.items.len - 1;
        }
    }
};
