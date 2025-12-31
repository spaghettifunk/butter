//! Metal buffer management.
//!
//! Handles creation and management of MTLBuffer objects for vertex,
//! index, and uniform buffers.

const std = @import("std");
const metal_context = @import("context.zig");
const logger = @import("../../core/logging.zig");

const MetalContext = metal_context.MetalContext;
const sel = metal_context.sel_registerName;
const msg = metal_context.msgSend;
const msg1 = metal_context.msgSend1;
const msg2 = metal_context.msgSend2;
const msg3 = metal_context.msgSend3;
const release = metal_context.release;

/// Metal buffer wrapper
pub const MetalBuffer = struct {
    handle: metal_context.MTLBuffer = null,
    size: u64 = 0,
};

/// Create a buffer with initial data (for vertex/index buffers)
/// Uses shared storage mode for CPU/GPU access on Apple Silicon
pub fn create(context: *MetalContext, size: u64, data: ?*const anyopaque) MetalBuffer {
    const device = context.device orelse return .{};

    if (size == 0) {
        logger.warn("Attempted to create zero-size buffer", .{});
        return .{};
    }

    var buffer: MetalBuffer = .{ .size = size };

    if (data) |ptr| {
        // Create buffer with data: newBufferWithBytes:length:options:
        buffer.handle = msg3(
            ?*anyopaque,
            device,
            sel("newBufferWithBytes:length:options:"),
            ptr,
            size,
            metal_context.MTLResourceOptions.StorageModeShared,
        );
    } else {
        // Create empty buffer: newBufferWithLength:options:
        buffer.handle = msg2(
            ?*anyopaque,
            device,
            sel("newBufferWithLength:options:"),
            size,
            metal_context.MTLResourceOptions.StorageModeShared,
        );
    }

    if (buffer.handle == null) {
        logger.err("Failed to create Metal buffer of size {}", .{size});
        return .{};
    }

    return buffer;
}

/// Create a buffer without initial data (for uniform buffers)
pub fn createEmpty(context: *MetalContext, size: u64) MetalBuffer {
    return create(context, size, null);
}

/// Update buffer contents at a given offset
pub fn update(buf: *MetalBuffer, offset: u64, size: u64, data: *const anyopaque) void {
    const handle = buf.handle orelse {
        logger.warn("Attempted to update null buffer", .{});
        return;
    };

    if (offset + size > buf.size) {
        logger.err("Buffer update out of bounds: offset {} + size {} > buffer size {}", .{ offset, size, buf.size });
        return;
    }

    // Get contents pointer: [buffer contents]
    const contents = msg(?*anyopaque, handle, sel("contents"));
    if (contents == null) {
        logger.err("Failed to get buffer contents pointer", .{});
        return;
    }

    // Copy data to buffer
    const dest: [*]u8 = @ptrCast(contents);
    const src: [*]const u8 = @ptrCast(data);
    @memcpy(dest[offset..][0..size], src[0..size]);
}

/// Lock buffer for CPU write access and return contents pointer
/// For Metal with shared storage mode, this is just getting the contents pointer
pub fn lock(buf: *MetalBuffer) ?*anyopaque {
    const handle = buf.handle orelse return null;
    return msg(?*anyopaque, handle, sel("contents"));
}

/// Unlock buffer after CPU write
/// For Metal with shared storage mode on Apple Silicon, this is a no-op
/// On Intel Macs with managed storage, you would call didModifyRange:
pub fn unlock(buf: *MetalBuffer) void {
    _ = buf;
    // No-op for shared storage mode on Apple Silicon
    // For managed storage mode, would need: [buffer didModifyRange:NSMakeRange(0, size)]
}

/// Destroy a buffer and release resources
pub fn destroy(buf: *MetalBuffer) void {
    if (buf.handle) |handle| {
        release(handle);
    }
    buf.* = .{};
}

/// Get the native MTLBuffer handle
pub fn getHandle(buf: *const MetalBuffer) ?*anyopaque {
    return buf.handle;
}

/// Check if buffer is valid
pub fn isValid(buf: *const MetalBuffer) bool {
    return buf.handle != null and buf.size > 0;
}
