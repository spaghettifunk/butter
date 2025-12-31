const std = @import("std");
const logger = @import("../core/logging.zig");
const memory = @import("../systems/memory.zig");

pub const FileMode = packed struct {
    read: bool = false,
    write: bool = false,
    _padding: u6 = 0,
};

pub const FileHandle = struct {
    handle: ?std.fs.File = null,
    is_valid: bool = false,
};

pub fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn open(path: []const u8, mode: FileMode, out_handle: *FileHandle) bool {
    out_handle.is_valid = false;
    out_handle.handle = null;

    if (mode.read and mode.write) {
        // Read and write mode
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch {
            // If file doesn't exist, create it
            const created = std.fs.cwd().createFile(path, .{ .read = true }) catch |e| {
                logger.err("Error opening file '{s}': {}", .{ path, e });
                return false;
            };
            out_handle.handle = created;
            out_handle.is_valid = true;
            return true;
        };
        out_handle.handle = file;
        out_handle.is_valid = true;
        return true;
    } else if (mode.read and !mode.write) {
        // Read only mode
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |e| {
            logger.err("Error opening file '{s}': {}", .{ path, e });
            return false;
        };
        out_handle.handle = file;
        out_handle.is_valid = true;
        return true;
    } else if (!mode.read and mode.write) {
        // Write only mode
        const file = std.fs.cwd().createFile(path, .{}) catch |e| {
            logger.err("Error opening file '{s}': {}", .{ path, e });
            return false;
        };
        out_handle.handle = file;
        out_handle.is_valid = true;
        return true;
    } else {
        logger.err("Invalid mode passed while trying to open file: '{s}'", .{path});
        return false;
    }
}

pub fn close(handle: *FileHandle) void {
    if (handle.handle) |file| {
        file.close();
        handle.handle = null;
        handle.is_valid = false;
    }
}

pub fn readLine(handle: *FileHandle, allocator: std.mem.Allocator) ?[]u8 {
    if (handle.handle) |file| {
        const reader = file.reader();
        const line = reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 32000) catch return null;
        return line;
    }
    return null;
}

pub fn writeLine(handle: *FileHandle, text: []const u8) bool {
    if (handle.handle) |file| {
        const writer = file.writer();
        writer.writeAll(text) catch return false;
        writer.writeByte('\n') catch return false;
        return true;
    }
    return false;
}

pub fn read(handle: *FileHandle, buffer: []u8, out_bytes_read: *usize) bool {
    if (handle.handle) |file| {
        const bytes_read = file.read(buffer) catch return false;
        out_bytes_read.* = bytes_read;
        if (bytes_read != buffer.len) {
            return false;
        }
        return true;
    }
    return false;
}

pub fn readAllBytes(handle: *FileHandle, allocator: std.mem.Allocator) ?[]u8 {
    if (handle.handle) |file| {
        const stat = file.stat() catch return null;
        const size = stat.size;

        const buffer = allocator.alloc(u8, size) catch return null;
        const bytes_read = file.readAll(buffer) catch {
            allocator.free(buffer);
            return null;
        };

        if (bytes_read != size) {
            allocator.free(buffer);
            return null;
        }

        return buffer;
    }
    return null;
}

pub fn write(handle: *FileHandle, data: []const u8, out_bytes_written: *usize) bool {
    if (handle.handle) |file| {
        const bytes_written = file.write(data) catch return false;
        out_bytes_written.* = bytes_written;
        if (bytes_written != data.len) {
            return false;
        }
        return true;
    }
    return false;
}

pub fn getFileSize(handle: *FileHandle) ?u64 {
    if (handle.handle) |file| {
        const stat = file.stat() catch return null;
        return stat.size;
    }
    return null;
}
