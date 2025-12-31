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

const stderr = std.fs.File.stderr();

fn write(comptime prefix: []const u8, comptime format: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, prefix ++ format ++ "\n", args) catch return;
    stderr.writeAll(msg) catch {};
}

pub fn trace(comptime format: []const u8, args: anytype) void {
    write(trace_prefix, format, args);
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    write(debug_prefix, format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    write(info_prefix, format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    write(warn_prefix, format, args);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    write(err_prefix, format, args);
}

pub fn fatal(comptime format: []const u8, args: anytype) void {
    write(fatal_prefix, format, args);
}
