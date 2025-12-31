const std = @import("std");

// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const gray = "\x1b[90m";
    const blue = "\x1b[34m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const red = "\x1b[31m";
    const bold_red = "\x1b[1;31m";
};

// Level prefixes with colors
const trace_prefix = Color.gray ++ "[TRACE]  ";
const debug_prefix = Color.blue ++ "[DEBUG]  ";
const info_prefix = Color.green ++ "[INFO]  ";
const warn_prefix = Color.yellow ++ "[WARN]  ";
const err_prefix = Color.red ++ "[ERROR]  ";
const fatal_prefix = Color.bold_red ++ "[FATAL]  ";

const context = @import("../context.zig");
var instance: LoggingSystem = undefined;

pub const LoggingSystem = struct {
    stderr: std.fs.File = std.fs.File.stderr(),
    log_file: ?std.fs.File = null,
    log_file_mutex: std.Thread.Mutex = .{},

    pub fn initialize(path: []const u8) bool {
        // already initialized
        if (instance.log_file != null) {
            return false;
        }

        const file = std.fs.cwd().createFile(path, .{
            .read = false,
            .truncate = false,
            .mode = 0o644,
        }) catch return false;

        instance = LoggingSystem{
            .log_file = file,
            .log_file_mutex = std.Thread.Mutex{},
        };
        context.get().logging = &instance;

        instance.write(info_prefix, "Logging initialized.", .{});

        return true;
    }

    pub fn shutdown() void {
        if (instance.log_file) |f| {
            f.close();
            instance.log_file = null;
        }

        context.get().logging = null;

        instance.write(info_prefix, "Logging shutdown.", .{});
    }

    fn write(self: *LoggingSystem, comptime prefix: []const u8, comptime format: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, prefix ++ format ++ "\n", args) catch return;
        self.stderr.writeAll(msg) catch {};

        // Optional file
        self.log_file_mutex.lock();
        defer self.log_file_mutex.unlock();

        if (self.log_file) |f| {
            f.writeAll(msg) catch {};
        }
    }
};

pub fn getSystem() ?*LoggingSystem {
    return context.get().logging;
}

pub fn trace(comptime format: []const u8, args: anytype) void {
    const sys = getSystem() orelse return;
    sys.write(trace_prefix, format, args);
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    const sys = getSystem() orelse return;
    sys.write(debug_prefix, format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    const sys = getSystem() orelse return;
    sys.write(info_prefix, format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    const sys = getSystem() orelse return;
    sys.write(warn_prefix, format, args);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    const sys = getSystem() orelse return;
    sys.write(err_prefix, format, args);
}

pub fn fatal(comptime format: []const u8, args: anytype) void {
    const sys = getSystem() orelse return;
    sys.write(fatal_prefix, format, args);
}
