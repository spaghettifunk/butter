//! Console Panel
//! Enhanced console with log display and command execution.

const std = @import("std");
const imgui = @import("../../systems/imgui.zig");
const logger = @import("../../core/logging.zig");

const c = imgui.c;

/// Log severity levels.
pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    err,
    fatal,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn getColor(self: LogLevel) imgui.ImVec4 {
        return switch (self) {
            .trace => .{ .x = 0.5, .y = 0.5, .z = 0.5, .w = 1.0 },
            .debug => .{ .x = 0.4, .y = 0.4, .z = 1.0, .w = 1.0 },
            .info => .{ .x = 0.4, .y = 1.0, .z = 0.4, .w = 1.0 },
            .warn => .{ .x = 1.0, .y = 1.0, .z = 0.4, .w = 1.0 },
            .err => .{ .x = 1.0, .y = 0.4, .z = 0.4, .w = 1.0 },
            .fatal => .{ .x = 1.0, .y = 0.2, .z = 0.2, .w = 1.0 },
        };
    }
};

/// A single log entry.
pub const LogEntry = struct {
    level: LogLevel,
    message: []const u8,
    timestamp: i64,
};

/// Console command callback type.
pub const CommandCallback = *const fn (args: []const u8, console: *ConsolePanel) void;

/// A registered console command.
const ConsoleCommand = struct {
    name: []const u8,
    description: []const u8,
    callback: CommandCallback,
};

pub const ConsolePanel = struct {
    allocator: std.mem.Allocator,

    /// Log entries.
    entries: std.ArrayList(LogEntry),

    /// Command input buffer.
    command_buffer: [256]u8 = [_]u8{0} ** 256,

    /// Command history.
    command_history: std.ArrayList([]const u8),

    /// Current history index (-1 = new command).
    history_index: i32 = -1,

    /// Whether to auto-scroll to bottom.
    auto_scroll: bool = true,

    /// Whether to scroll to bottom on next frame.
    scroll_to_bottom: bool = false,

    /// Log level filters.
    show_trace: bool = false,
    show_debug: bool = true,
    show_info: bool = true,
    show_warn: bool = true,
    show_error: bool = true,

    /// Registered commands.
    commands: std.StringHashMap(ConsoleCommand),

    /// Initialize the console panel.
    pub fn init(allocator: std.mem.Allocator) ConsolePanel {
        var self = ConsolePanel{
            .allocator = allocator,
            .entries = .empty, // try std.ArrayList(LogEntry).initCapacity(allocator, 64),
            .command_history = .empty, //try std.ArrayList([]const u8).initCapacity(allocator, 64),
            .commands = std.StringHashMap(ConsoleCommand).init(allocator),
        };

        // Register built-in commands
        self.registerCommand("clear", "Clear the console", cmdClear);
        self.registerCommand("help", "Show available commands", cmdHelp);
        self.registerCommand("echo", "Echo the input text", cmdEcho);

        return self;
    }

    /// Shutdown and free resources.
    pub fn deinit(self: *ConsolePanel) void {
        // Free log entry messages
        for (self.entries.items) |entry| {
            self.allocator.free(entry.message);
        }
        self.entries.deinit(self.allocator);

        // Free command history
        for (self.command_history.items) |cmd| {
            self.allocator.free(cmd);
        }
        self.command_history.deinit(self.allocator);

        self.commands.deinit();
    }

    /// Add a log entry.
    pub fn addLog(self: *ConsolePanel, level: LogLevel, message: []const u8) void {
        const msg_copy = self.allocator.dupe(u8, message) catch return;
        self.entries.append(self.allocator, .{
            .level = level,
            .message = msg_copy,
            .timestamp = std.time.timestamp(),
        }) catch {
            self.allocator.free(msg_copy);
            return;
        };

        if (self.auto_scroll) {
            self.scroll_to_bottom = true;
        }
    }

    /// Add a formatted log entry.
    pub fn addLogFmt(self: *ConsolePanel, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.addLog(level, message);
    }

    /// Register a console command.
    pub fn registerCommand(self: *ConsolePanel, name: []const u8, description: []const u8, callback: CommandCallback) void {
        self.commands.put(name, .{
            .name = name,
            .description = description,
            .callback = callback,
        }) catch return;
    }

    /// Execute a command string.
    pub fn executeCommand(self: *ConsolePanel, input: []const u8) void {
        if (input.len == 0) return;

        // Log the command
        self.addLogFmt(.info, "> {s}", .{input});

        // Parse command and args
        var iter = std.mem.splitScalar(u8, input, ' ');
        const cmd_name = iter.next() orelse return;
        const args = iter.rest();

        // Look up and execute command
        if (self.commands.get(cmd_name)) |cmd| {
            cmd.callback(args, self);
        } else {
            self.addLogFmt(.err, "Unknown command: {s}. Type 'help' for available commands.", .{cmd_name});
        }

        // Add to history
        const history_entry = self.allocator.dupe(u8, input) catch return;
        self.command_history.append(self.allocator, history_entry) catch {
            self.allocator.free(history_entry);
        };
        self.history_index = -1;
    }

    /// Clear all log entries.
    pub fn clear(self: *ConsolePanel) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.message);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Render the console panel.
    pub fn render(self: *ConsolePanel, p_open: *bool) void {
        if (imgui.begin("Console", p_open, imgui.WindowFlags.MenuBar)) {
            // Menu bar
            if (imgui.beginMenuBar()) {
                if (imgui.beginMenu("Options")) {
                    _ = c.ImGui_Checkbox("Auto-scroll", &self.auto_scroll);
                    imgui.separator();
                    if (imgui.menuItem("Clear")) {
                        self.clear();
                    }
                    imgui.endMenu();
                }

                if (imgui.beginMenu("Filter")) {
                    _ = c.ImGui_Checkbox("Trace", &self.show_trace);
                    _ = c.ImGui_Checkbox("Debug", &self.show_debug);
                    _ = c.ImGui_Checkbox("Info", &self.show_info);
                    _ = c.ImGui_Checkbox("Warn", &self.show_warn);
                    _ = c.ImGui_Checkbox("Error", &self.show_error);
                    imgui.endMenu();
                }

                imgui.endMenuBar();
            }

            // Log entries (scrollable region)
            const footer_height = imgui.getFrameHeightWithSpacing() + 4;

            if (imgui.beginChild("##log_region", .{ .x = 0, .y = -footer_height }, imgui.ChildFlags.None, imgui.WindowFlags.HorizontalScrollbar)) {
                for (self.entries.items) |entry| {
                    if (!self.shouldShowLevel(entry.level)) continue;

                    // Format: [LEVEL] message
                    var buf: [16]u8 = undefined;
                    const prefix = std.fmt.bufPrintZ(&buf, "[{s}]", .{entry.level.toString()}) catch "[???]";

                    imgui.textColored(entry.level.getColor(), prefix);
                    imgui.sameLine();
                    imgui.text(@ptrCast(entry.message.ptr));
                }

                // Auto-scroll
                if (self.scroll_to_bottom and imgui.getScrollY() >= imgui.getScrollMaxY() - 20) {
                    imgui.setScrollHereY(1.0);
                }
                self.scroll_to_bottom = false;
            }
            imgui.endChild();

            // Command input
            imgui.separator();

            var reclaim_focus = false;
            imgui.pushItemWidth(-1);

            // For console input with history callback, just use simple input
            // (callback support would require more complex wrapper)
            const input_flags = imgui.InputTextFlags.EnterReturnsTrue;

            if (c.ImGui_InputTextWithHintEx(
                "##command_input",
                "Enter command...",
                &self.command_buffer,
                self.command_buffer.len,
                input_flags | c.ImGuiInputTextFlags_EscapeClearsAll,
                null,
                null,
            )) {
                // Get command length
                const len = std.mem.indexOfScalar(u8, &self.command_buffer, 0) orelse 0;
                if (len > 0) {
                    self.executeCommand(self.command_buffer[0..len]);
                    self.command_buffer = [_]u8{0} ** 256;
                }
                reclaim_focus = true;
            }

            imgui.popItemWidth();

            // Keep focus on input
            imgui.setItemDefaultFocus();
            if (reclaim_focus) {
                imgui.setKeyboardFocusHereEx(-1);
            }
        }
        imgui.end();
    }

    /// Check if a log level should be displayed.
    fn shouldShowLevel(self: *ConsolePanel, level: LogLevel) bool {
        return switch (level) {
            .trace => self.show_trace,
            .debug => self.show_debug,
            .info => self.show_info,
            .warn => self.show_warn,
            .err, .fatal => self.show_error,
        };
    }

    /// History callback for ImGui input.
    fn historyCallback(data: [*c]c.ImGuiInputTextCallbackData) callconv(.c) c_int {
        const self: *ConsolePanel = @ptrCast(@alignCast(data.*.UserData));

        if (data.*.EventFlag == c.ImGuiInputTextFlags_CallbackHistory) {
            const history_len: i32 = @intCast(self.command_history.items.len);

            if (data.*.EventKey == c.ImGuiKey_UpArrow) {
                if (self.history_index < history_len - 1) {
                    self.history_index += 1;
                }
            } else if (data.*.EventKey == c.ImGuiKey_DownArrow) {
                if (self.history_index > -1) {
                    self.history_index -= 1;
                }
            }

            if (self.history_index >= 0 and self.history_index < history_len) {
                const idx: usize = @intCast(history_len - 1 - self.history_index);
                const history_entry = self.command_history.items[idx];

                // Copy to buffer
                c.ImGuiInputTextCallbackData_DeleteChars(data, 0, data.*.BufTextLen);
                c.ImGuiInputTextCallbackData_InsertChars(data, 0, history_entry.ptr, history_entry.ptr + history_entry.len);
            } else if (self.history_index == -1) {
                c.ImGuiInputTextCallbackData_DeleteChars(data, 0, data.*.BufTextLen);
            }
        }

        return 0;
    }
};

// Built-in command implementations

fn cmdClear(_: []const u8, console: *ConsolePanel) void {
    console.clear();
}

fn cmdHelp(_: []const u8, console: *ConsolePanel) void {
    console.addLog(.info, "Available commands:");
    var iter = console.commands.iterator();
    while (iter.next()) |entry| {
        const cmd = entry.value_ptr;
        console.addLogFmt(.info, "  {s} - {s}", .{ cmd.name, cmd.description });
    }
}

fn cmdEcho(args: []const u8, console: *ConsolePanel) void {
    if (args.len > 0) {
        console.addLog(.info, args);
    }
}
