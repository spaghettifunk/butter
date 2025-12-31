//! Metal texture management.
//!
//! Handles creation and management of MTLTexture and MTLSamplerState objects.

const std = @import("std");
const metal_context = @import("context.zig");
const logger = @import("../../core/logging.zig");

const MetalContext = metal_context.MetalContext;
const sel = metal_context.sel_registerName;
const msg = metal_context.msgSend;
const msg1 = metal_context.msgSend1;
const msg4 = metal_context.msgSend4;
const msg5 = metal_context.msgSend5;
const getClass = metal_context.objc_getClass;
const release = metal_context.release;

/// Metal texture wrapper
pub const MetalTexture = struct {
    handle: metal_context.MTLTexture = null,
    sampler: metal_context.MTLSamplerState = null,
    width: u32 = 0,
    height: u32 = 0,
    channel_count: u8 = 0,
};

/// Create a texture from raw pixel data
pub fn create(
    context: *MetalContext,
    width: u32,
    height: u32,
    channel_count: u8,
    pixels: []const u8,
) ?MetalTexture {
    const device = context.device orelse {
        logger.err("Cannot create texture: no Metal device", .{});
        return null;
    };

    if (width == 0 or height == 0) {
        logger.err("Cannot create texture with zero dimensions", .{});
        return null;
    }

    // Determine pixel format based on channel count
    const pixel_format: u64 = switch (channel_count) {
        1 => metal_context.MTLPixelFormat.R8Unorm,
        2 => metal_context.MTLPixelFormat.RG8Unorm,
        4 => metal_context.MTLPixelFormat.RGBA8Unorm,
        else => {
            logger.err("Unsupported texture channel count: {}", .{channel_count});
            return null;
        },
    };

    // Create texture descriptor
    const desc_class = getClass("MTLTextureDescriptor") orelse {
        logger.err("Failed to get MTLTextureDescriptor class", .{});
        return null;
    };

    const desc = msg4(
        ?*anyopaque,
        desc_class,
        sel("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
        pixel_format,
        @as(u64, width),
        @as(u64, height),
        @as(i8, 0), // NO mipmaps
    );
    if (desc == null) {
        logger.err("Failed to create texture descriptor", .{});
        return null;
    }

    // Set usage to shader read
    _ = msg1(void, desc, sel("setUsage:"), metal_context.MTLTextureUsage.ShaderRead);

    // Create texture
    const texture = msg1(?*anyopaque, device, sel("newTextureWithDescriptor:"), desc);
    if (texture == null) {
        logger.err("Failed to create texture", .{});
        return null;
    }

    // Upload pixel data
    const region = metal_context.MTLRegion{
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .size = .{ .width = width, .height = height, .depth = 1 },
    };
    const bytes_per_row: u64 = @as(u64, width) * @as(u64, channel_count);

    // replaceRegion:mipmapLevel:withBytes:bytesPerRow:
    _ = msg4(
        void,
        texture,
        sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
        region,
        @as(u64, 0), // mipmap level 0
        pixels.ptr,
        bytes_per_row,
    );

    // Create sampler
    const sampler = createSampler(device) orelse {
        logger.err("Failed to create sampler", .{});
        release(texture);
        return null;
    };

    logger.debug("Created texture {}x{} channels={}", .{ width, height, channel_count });

    return MetalTexture{
        .handle = texture,
        .sampler = sampler,
        .width = width,
        .height = height,
        .channel_count = channel_count,
    };
}

/// Create a default checkerboard texture (8x8 with 2x2 squares)
pub fn createDefaultTexture(context: *MetalContext) ?MetalTexture {
    const size: u32 = 8;
    const square_size: u32 = 2;
    var pixels: [size * size * 4]u8 = undefined;

    for (0..size) |y| {
        for (0..size) |x| {
            const idx = (y * size + x) * 4;
            // Checkerboard pattern with 2x2 squares
            const is_white = ((x / square_size) + (y / square_size)) % 2 == 0;
            const color: u8 = if (is_white) 255 else 128;
            pixels[idx + 0] = color; // R
            pixels[idx + 1] = color; // G
            pixels[idx + 2] = color; // B
            pixels[idx + 3] = 255; // A
        }
    }

    return create(context, size, size, 4, &pixels);
}

/// Create a sampler state with linear filtering
fn createSampler(device: ?*anyopaque) ?*anyopaque {
    const desc_class = getClass("MTLSamplerDescriptor") orelse return null;

    const desc_alloc = msg(?*anyopaque, desc_class, sel("alloc"));
    if (desc_alloc == null) return null;

    const desc = msg(?*anyopaque, desc_alloc, sel("init"));
    if (desc == null) return null;

    // Set filtering
    _ = msg1(void, desc, sel("setMinFilter:"), metal_context.MTLSamplerMinMagFilter.Linear);
    _ = msg1(void, desc, sel("setMagFilter:"), metal_context.MTLSamplerMinMagFilter.Linear);
    _ = msg1(void, desc, sel("setMipFilter:"), @as(u64, 0)); // MTLSamplerMipFilterNotMipmapped

    // Set address modes
    _ = msg1(void, desc, sel("setSAddressMode:"), metal_context.MTLSamplerAddressMode.Repeat);
    _ = msg1(void, desc, sel("setTAddressMode:"), metal_context.MTLSamplerAddressMode.Repeat);

    // Create sampler state
    const sampler = msg1(?*anyopaque, device, sel("newSamplerStateWithDescriptor:"), desc);
    release(desc);

    return sampler;
}

/// Destroy a texture and release resources
pub fn destroy(texture: *MetalTexture) void {
    if (texture.sampler) |sampler| {
        release(sampler);
    }
    if (texture.handle) |handle| {
        release(handle);
    }
    texture.* = .{};
}

/// Bind a texture to the fragment shader at texture index 0
pub fn bind(encoder: ?*anyopaque, texture: *const MetalTexture) void {
    const enc = encoder orelse return;
    const msg2 = metal_context.msgSend2;

    if (texture.handle) |tex| {
        // setFragmentTexture:atIndex:
        _ = msg2(
            void,
            enc,
            sel("setFragmentTexture:atIndex:"),
            tex,
            @as(u64, 0), // Texture index 0
        );
    }

    if (texture.sampler) |sampler| {
        // setFragmentSamplerState:atIndex:
        _ = msg2(
            void,
            enc,
            sel("setFragmentSamplerState:atIndex:"),
            sampler,
            @as(u64, 0), // Sampler index 0
        );
    }
}

/// Check if texture is valid
pub fn isValid(texture: *const MetalTexture) bool {
    return texture.handle != null;
}

/// Get the MTLTexture handle
pub fn getHandle(texture: *const MetalTexture) ?*anyopaque {
    return texture.handle;
}
