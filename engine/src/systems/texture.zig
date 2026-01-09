//! TextureSystem - Manages texture resources with ID-based registry.
//!
//! Provides:
//! - Auto-incrementing texture IDs
//! - Path-based texture cache/lookup
//! - Reference counting for textures
//! - Default texture management
//! - Backend-agnostic interface (delegates GPU work to renderer)

const std = @import("std");
const context = @import("../context.zig");
const logger = @import("../core/logging.zig");
const filesystem = @import("../platform/filesystem.zig");
const resource_types = @import("../resources/types.zig");
const renderer = @import("../renderer/renderer.zig");
const jobs = @import("jobs.zig");

// stb_image import for image loading
const stbImage = @cImport({
    @cInclude("stb_image.h");
});

/// Invalid texture ID constant
pub const INVALID_TEXTURE_ID: u32 = 0;

/// Maximum number of textures that can be registered
pub const MAX_TEXTURES: usize = 1024;

/// Texture entry in the registry
const TextureEntry = struct {
    texture: resource_types.Texture,
    path: ?[]const u8, // null for programmatic textures
    ref_count: u32,
    is_valid: bool,
};

/// Options for loading a texture
pub const LoadOptions = struct {
    /// Force a specific number of channels (0 = use image's native channels)
    desired_channels: u8 = 4,
    /// Flip the image vertically (useful for OpenGL coordinate system)
    flip_vertical: bool = false,
};

// Private instance storage
var instance: TextureSystem = undefined;

pub const TextureSystem = struct {
    /// Texture registry - index is texture ID - 1 (ID 0 is invalid)
    textures: [MAX_TEXTURES]TextureEntry,

    /// Path to texture ID lookup (for caching)
    path_lookup: std.StringHashMap(u32),

    /// Next available texture ID
    next_id: u32,

    /// Default texture ID (checkerboard)
    default_texture_id: u32,

    /// Initialize the texture system (called after renderer is initialized)
    pub fn initialize() bool {
        instance = TextureSystem{
            .textures = [_]TextureEntry{.{
                .texture = .{
                    .id = 0,
                    .width = 0,
                    .height = 0,
                    .channel_count = 0,
                    .has_transparency = false,
                    .generation = 0,
                    .internal_data = null,
                },
                .path = null,
                .ref_count = 0,
                .is_valid = false,
            }} ** MAX_TEXTURES,
            .path_lookup = std.StringHashMap(u32).init(std.heap.page_allocator),
            .next_id = 1, // Start at 1, 0 is invalid
            .default_texture_id = INVALID_TEXTURE_ID,
        };

        // Create default texture
        if (!instance.createDefaultTexture()) {
            logger.err("Failed to create default texture", .{});
            return false;
        }

        // Register with engine context
        context.get().texture = &instance;
        logger.info("Texture system initialized.", .{});
        return true;
    }

    /// Shutdown the texture system
    pub fn shutdown() void {
        const sys = context.get().texture orelse return;

        // Destroy all textures
        for (&sys.textures) |*entry| {
            if (entry.is_valid) {
                if (renderer.getSystem()) |render_sys| {
                    render_sys.destroyTexture(&entry.texture);
                }
                if (entry.path) |path| {
                    std.heap.page_allocator.free(path);
                }
                entry.is_valid = false;
            }
        }

        sys.path_lookup.deinit();
        context.get().texture = null;
        logger.info("Texture system shutdown.", .{});
    }

    // ========== Public API ==========

    /// Load a texture from file path. Returns texture ID or INVALID_TEXTURE_ID on failure.
    /// If the texture is already loaded, increments ref count and returns existing ID.
    pub fn loadFromFile(self: *TextureSystem, path: []const u8) u32 {
        return self.loadFromFileWithOptions(path, .{});
    }

    /// Load a texture with options. Returns texture ID or INVALID_TEXTURE_ID.
    pub fn loadFromFileWithOptions(self: *TextureSystem, path: []const u8, options: LoadOptions) u32 {
        // Check cache first
        if (self.path_lookup.get(path)) |existing_id| {
            // Increment ref count and return
            const idx = existing_id - 1;
            self.textures[idx].ref_count += 1;
            logger.debug("Texture cache hit: {s} (id={}, ref_count={})", .{ path, existing_id, self.textures[idx].ref_count });
            return existing_id;
        }

        // Open the file to read its contents
        var file_handle: filesystem.FileHandle = .{};
        if (!filesystem.open(path, .{ .read = true }, &file_handle)) {
            logger.err("Failed to open image file: {s}", .{path});
            return INVALID_TEXTURE_ID;
        }
        defer filesystem.close(&file_handle);

        // Read all file bytes
        const file_data = filesystem.readAllBytes(&file_handle, std.heap.page_allocator) orelse {
            logger.err("Failed to read image file: {s}", .{path});
            return INVALID_TEXTURE_ID;
        };
        defer std.heap.page_allocator.free(file_data);

        // Load from memory
        const texture_id = self.loadFromMemoryInternal(file_data, options, path);
        if (texture_id == INVALID_TEXTURE_ID) {
            return INVALID_TEXTURE_ID;
        }

        // Store path for cache lookup
        const path_copy = std.heap.page_allocator.dupe(u8, path) catch {
            logger.err("Failed to allocate path for texture cache", .{});
            return texture_id; // Still return the valid texture, just won't be cached
        };

        const idx = texture_id - 1;
        self.textures[idx].path = path_copy;
        self.path_lookup.put(path_copy, texture_id) catch {
            logger.warn("Failed to add texture to cache: {s}", .{path});
            std.heap.page_allocator.free(path_copy);
            self.textures[idx].path = null;
        };

        return texture_id;
    }

    /// Load a texture from raw file data in memory
    fn loadFromMemoryInternal(self: *TextureSystem, file_data: []const u8, options: LoadOptions, debug_name: []const u8) u32 {
        // Set flip option
        stbImage.stbi_set_flip_vertically_on_load(if (options.flip_vertical) 1 else 0);

        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;

        const desired_channels: c_int = @intCast(options.desired_channels);

        // Load the image
        const pixels = stbImage.stbi_load_from_memory(
            file_data.ptr,
            @intCast(file_data.len),
            &width,
            &height,
            &channels,
            desired_channels,
        );

        if (pixels == null) {
            const failure_reason = stbImage.stbi_failure_reason();
            if (failure_reason != null) {
                logger.err("Failed to load image '{s}': {s}", .{ debug_name, failure_reason });
            } else {
                logger.err("Failed to load image '{s}': unknown error", .{debug_name});
            }
            return INVALID_TEXTURE_ID;
        }
        defer stbImage.stbi_image_free(pixels);

        // Determine actual channel count
        const actual_channels: u8 = if (options.desired_channels != 0)
            options.desired_channels
        else
            @intCast(channels);

        // Determine if image has transparency
        const has_transparency = actual_channels == 4;

        // Calculate pixel data size
        const pixel_count: usize = @intCast(width * height);
        const pixel_data_size = pixel_count * @as(usize, actual_channels);

        // Create slice from the C pointer
        const pixel_slice: []const u8 = pixels[0..pixel_data_size];

        return self.createFromPixelsInternal(
            @intCast(width),
            @intCast(height),
            actual_channels,
            has_transparency,
            pixel_slice,
            debug_name,
        );
    }

    /// Create a texture from raw pixel data. Returns texture ID.
    pub fn createFromPixels(
        self: *TextureSystem,
        width: u32,
        height: u32,
        channel_count: u8,
        has_transparency: bool,
        pixels: []const u8,
    ) u32 {
        return self.createFromPixelsInternal(width, height, channel_count, has_transparency, pixels, "programmatic");
    }

    fn createFromPixelsInternal(
        self: *TextureSystem,
        width: u32,
        height: u32,
        channel_count: u8,
        has_transparency: bool,
        pixels: []const u8,
        debug_name: []const u8,
    ) u32 {
        // Allocate texture ID
        const texture_id = self.allocateId() orelse {
            logger.err("No free texture slots available", .{});
            return INVALID_TEXTURE_ID;
        };

        const idx = texture_id - 1;
        var entry = &self.textures[idx];

        // Get the renderer system and create the GPU texture
        const render_sys = renderer.getSystem() orelse {
            logger.err("Renderer system not available for texture creation", .{});
            return INVALID_TEXTURE_ID;
        };

        if (!render_sys.createTexture(
            &entry.texture,
            width,
            height,
            channel_count,
            has_transparency,
            pixels,
        )) {
            logger.err("Failed to create GPU texture for '{s}'", .{debug_name});
            return INVALID_TEXTURE_ID;
        }

        entry.texture.id = texture_id;
        entry.ref_count = 1;
        entry.is_valid = true;
        entry.path = null;

        logger.info("Texture created: {s} (id={}, {}x{}, {} channels)", .{
            debug_name,
            texture_id,
            width,
            height,
            channel_count,
        });

        return texture_id;
    }

    /// Load a cubemap from 6 separate image files
    /// Face order: +X (right), -X (left), +Y (top), -Y (bottom), +Z (front), -Z (back)
    pub fn loadCubemapFromFiles(self: *TextureSystem, face_paths: [6][]const u8) u32 {
        // Build cache key from all 6 paths
        var cache_key_buffer: [1024]u8 = undefined;
        var cache_key_stream = std.io.fixedBufferStream(&cache_key_buffer);
        const writer = cache_key_stream.writer();
        for (face_paths) |path| {
            writer.writeAll(path) catch break;
            writer.writeByte('|') catch break;
        }
        const cache_key = cache_key_stream.getWritten();

        // Check cache first
        if (self.path_lookup.get(cache_key)) |existing_id| {
            const idx = existing_id - 1;
            self.textures[idx].ref_count += 1;
            logger.debug("Cubemap cache hit: (id={}, ref_count={})", .{ existing_id, self.textures[idx].ref_count });
            return existing_id;
        }

        // Load all 6 faces
        var face_pixels: [6][]u8 = undefined;
        var width: u32 = 0;
        var height: u32 = 0;
        var channels: u8 = 0;

        for (face_paths, 0..) |path, i| {
            // Open file
            var file_handle: filesystem.FileHandle = .{};
            if (!filesystem.open(path, .{ .read = true }, &file_handle)) {
                logger.err("Failed to open cubemap face {}: {s}", .{ i, path });
                // Free already loaded faces
                for (0..i) |j| {
                    stbImage.stbi_image_free(face_pixels[j].ptr);
                }
                return INVALID_TEXTURE_ID;
            }
            defer filesystem.close(&file_handle);

            // Read file data
            const file_data = filesystem.readAllBytes(&file_handle, std.heap.page_allocator) orelse {
                logger.err("Failed to read cubemap face {}: {s}", .{ i, path });
                for (0..i) |j| {
                    stbImage.stbi_image_free(face_pixels[j].ptr);
                }
                return INVALID_TEXTURE_ID;
            };
            defer std.heap.page_allocator.free(file_data);

            // Decode image
            stbImage.stbi_set_flip_vertically_on_load(0); // Don't flip cubemap faces

            var w: c_int = 0;
            var h: c_int = 0;
            var ch: c_int = 0;

            const pixels = stbImage.stbi_load_from_memory(
                file_data.ptr,
                @intCast(file_data.len),
                &w,
                &h,
                &ch,
                4, // Force RGBA
            );

            if (pixels == null) {
                const failure_reason = stbImage.stbi_failure_reason();
                if (failure_reason != null) {
                    logger.err("Failed to decode cubemap face {}: {s} - {s}", .{ i, path, failure_reason });
                } else {
                    logger.err("Failed to decode cubemap face {}: {s}", .{ i, path });
                }
                for (0..i) |j| {
                    stbImage.stbi_image_free(face_pixels[j].ptr);
                }
                return INVALID_TEXTURE_ID;
            }

            // First face sets dimensions
            if (i == 0) {
                width = @intCast(w);
                height = @intCast(h);
                channels = 4;
            } else {
                // Validate all faces match
                if (w != width or h != height) {
                    logger.err("Cubemap face {} dimensions mismatch: {}x{} vs {}x{}", .{ i, w, h, width, height });
                    for (0..i) |j| {
                        stbImage.stbi_image_free(face_pixels[j].ptr);
                    }
                    stbImage.stbi_image_free(pixels);
                    return INVALID_TEXTURE_ID;
                }
            }

            const pixel_count: usize = @as(usize, width) * @as(usize, height) * @as(usize, channels);
            face_pixels[i] = pixels[0..pixel_count];
        }
        defer for (face_pixels) |face| {
            stbImage.stbi_image_free(face.ptr);
        };

        // Allocate texture ID
        const texture_id = self.allocateId() orelse {
            logger.err("No free texture slots for cubemap", .{});
            return INVALID_TEXTURE_ID;
        };

        const idx = texture_id - 1;
        var entry = &self.textures[idx];

        // Get renderer and create cubemap
        const render_sys = renderer.getSystem() orelse {
            logger.err("Renderer not available for cubemap creation", .{});
            return INVALID_TEXTURE_ID;
        };

        if (!render_sys.createTextureCubemap(
            &entry.texture,
            width,
            height,
            channels,
            face_pixels,
        )) {
            logger.err("Failed to create GPU cubemap texture", .{});
            return INVALID_TEXTURE_ID;
        }

        entry.texture.id = texture_id;
        entry.ref_count = 1;
        entry.is_valid = true;

        // Cache the cubemap
        const cache_key_copy = std.heap.page_allocator.dupe(u8, cache_key) catch {
            logger.warn("Failed to allocate cache key for cubemap", .{});
            return texture_id; // Still valid, just not cached
        };

        entry.path = cache_key_copy;
        self.path_lookup.put(cache_key_copy, texture_id) catch {
            logger.warn("Failed to add cubemap to cache", .{});
            std.heap.page_allocator.free(cache_key_copy);
            entry.path = null;
        };

        logger.info("Cubemap texture loaded: id={}, {}x{}", .{ texture_id, width, height });
        return texture_id;
    }

    /// Get a texture by ID. Returns null if invalid.
    pub fn getTexture(self: *TextureSystem, id: u32) ?*resource_types.Texture {
        if (id == INVALID_TEXTURE_ID) return null;

        const idx = id - 1;
        if (idx >= MAX_TEXTURES) return null;
        if (!self.textures[idx].is_valid) return null;

        return &self.textures[idx].texture;
    }

    /// Acquire a reference to a texture (increment ref count)
    pub fn acquire(self: *TextureSystem, id: u32) void {
        if (id == INVALID_TEXTURE_ID) return;
        const idx = id - 1;
        if (idx < MAX_TEXTURES and self.textures[idx].is_valid) {
            self.textures[idx].ref_count += 1;
        }
    }

    /// Release a texture reference. Destroys texture when ref count reaches 0.
    pub fn release(self: *TextureSystem, id: u32) void {
        if (id == INVALID_TEXTURE_ID) return;

        const idx = id - 1;
        if (idx >= MAX_TEXTURES or !self.textures[idx].is_valid) return;

        if (self.textures[idx].ref_count > 0) {
            self.textures[idx].ref_count -= 1;
        }

        if (self.textures[idx].ref_count == 0) {
            // Don't destroy default texture through release
            if (id == self.default_texture_id) {
                self.textures[idx].ref_count = 1; // Keep default texture alive
                return;
            }

            // Destroy the texture
            if (renderer.getSystem()) |render_sys| {
                render_sys.destroyTexture(&self.textures[idx].texture);
            }

            // Remove from path cache if it had a path
            if (self.textures[idx].path) |path| {
                _ = self.path_lookup.remove(path);
                std.heap.page_allocator.free(path);
            }

            self.textures[idx].is_valid = false;
            self.textures[idx].path = null;
            logger.debug("Texture released and destroyed (id={})", .{id});
        }
    }

    /// Get the default texture ID
    pub fn getDefaultTextureId(self: *TextureSystem) u32 {
        return self.default_texture_id;
    }

    /// Get the default texture
    pub fn getDefaultTexture(self: *TextureSystem) ?*resource_types.Texture {
        return self.getTexture(self.default_texture_id);
    }

    /// Bind a texture for rendering by ID. Pass INVALID_TEXTURE_ID for default.
    pub fn bind(self: *TextureSystem, id: u32) void {
        const tex = if (id == INVALID_TEXTURE_ID)
            self.getDefaultTexture()
        else
            self.getTexture(id);

        if (renderer.getSystem()) |render_sys| {
            render_sys.bindTexture(tex);
        }
    }

    // ========== Private helpers ==========

    fn createDefaultTexture(self: *TextureSystem) bool {
        // Create 8x8 checkerboard pattern
        const size: u32 = 8;
        const square_size: u32 = 2;
        const light_gray = [4]u8{ 200, 200, 200, 255 };
        const dark_gray = [4]u8{ 100, 100, 100, 255 };

        var pixels: [size * size * 4]u8 = undefined;

        for (0..size) |y| {
            for (0..size) |x| {
                const idx = (y * size + x) * 4;
                const square_x = x / square_size;
                const square_y = y / square_size;
                const is_light = (square_x + square_y) % 2 == 0;

                const color = if (is_light) light_gray else dark_gray;
                pixels[idx + 0] = color[0];
                pixels[idx + 1] = color[1];
                pixels[idx + 2] = color[2];
                pixels[idx + 3] = color[3];
            }
        }

        const id = self.createFromPixelsInternal(size, size, 4, false, &pixels, "default_checkerboard");
        if (id == INVALID_TEXTURE_ID) return false;

        self.default_texture_id = id;
        logger.info("Default texture created (id={})", .{id});
        return true;
    }

    fn allocateId(self: *TextureSystem) ?u32 {
        // First try using next_id if it's still valid
        if (self.next_id <= MAX_TEXTURES) {
            const id = self.next_id;
            self.next_id += 1;
            return id;
        }

        // Otherwise, find a free slot
        for (self.textures, 0..) |entry, i| {
            if (!entry.is_valid) {
                return @intCast(i + 1);
            }
        }

        return null; // No free slots
    }

    // ========== Async Loading API ==========

    /// Async texture loading arguments
    const AsyncLoadArgs = struct {
        path_copy: []const u8,
        options: LoadOptions,
        callback: ?*const fn (u32) void,
    };

    /// Load texture asynchronously using job system
    /// Returns job handle that can be waited on
    /// Callback is invoked on main thread when loading completes
    pub fn loadFromFileAsync(
        self: *TextureSystem,
        path: []const u8,
        options: LoadOptions,
        callback: ?*const fn (u32) void,
    ) !jobs.JobHandle {
        _ = self;

        // Check if already cached
        const sys = getSystem() orelse return error.SystemNotInitialized;
        if (sys.path_lookup.get(path)) |existing_id| {
            const idx = existing_id - 1;
            sys.textures[idx].ref_count += 1;
            logger.debug("Texture cache hit (async): {s} (id={}, ref_count={})", .{ path, existing_id, sys.textures[idx].ref_count });

            // Immediately invoke callback with cached texture
            if (callback) |cb| {
                cb(existing_id);
            }

            // Return invalid handle since job didn't run
            return jobs.INVALID_JOB_HANDLE;
        }

        // Duplicate path for the job (freed in job function)
        const path_copy = try std.heap.page_allocator.dupe(u8, path);
        errdefer std.heap.page_allocator.free(path_copy);

        const jobs_sys = context.get().jobs orelse return error.JobSystemNotInitialized;

        // Submit background job for I/O and decoding
        const load_handle = try jobs_sys.submit(asyncLoadJob, .{AsyncLoadArgs{
            .path_copy = path_copy,
            .options = options,
            .callback = callback,
        }});

        return load_handle;
    }

    /// Background job that loads texture from file
    fn asyncLoadJob(args: AsyncLoadArgs) void {
        defer std.heap.page_allocator.free(args.path_copy);

        _ = getSystem() orelse {
            logger.err("Texture system not available in async load job", .{});
            if (args.callback) |cb| cb(INVALID_TEXTURE_ID);
            return;
        };

        // 1. Load file from disk (I/O-bound)
        var file_handle: filesystem.FileHandle = .{};
        if (!filesystem.open(args.path_copy, .{ .read = true }, &file_handle)) {
            logger.err("Failed to open image file (async): {s}", .{args.path_copy});
            if (args.callback) |cb| cb(INVALID_TEXTURE_ID);
            return;
        }
        defer filesystem.close(&file_handle);

        const file_data = filesystem.readAllBytes(&file_handle, std.heap.page_allocator) orelse {
            logger.err("Failed to read image file (async): {s}", .{args.path_copy});
            if (args.callback) |cb| cb(INVALID_TEXTURE_ID);
            return;
        };
        defer std.heap.page_allocator.free(file_data);

        // 2. Decode image (CPU-bound)
        stbImage.stbi_set_flip_vertically_on_load(if (args.options.flip_vertical) 1 else 0);

        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        const desired_channels: c_int = @intCast(args.options.desired_channels);

        const pixels = stbImage.stbi_load_from_memory(
            file_data.ptr,
            @intCast(file_data.len),
            &width,
            &height,
            &channels,
            desired_channels,
        );

        if (pixels == null) {
            const failure_reason = stbImage.stbi_failure_reason();
            if (failure_reason != null) {
                logger.err("Failed to decode image (async) '{s}': {s}", .{ args.path_copy, failure_reason });
            } else {
                logger.err("Failed to decode image (async) '{s}': unknown error", .{args.path_copy});
            }
            if (args.callback) |cb| cb(INVALID_TEXTURE_ID);
            return;
        }
        defer stbImage.stbi_image_free(pixels);

        const actual_channels: u8 = if (args.options.desired_channels != 0)
            args.options.desired_channels
        else
            @intCast(channels);

        const has_transparency = actual_channels == 4;
        const pixel_count: usize = @intCast(width * height);
        const pixel_data_size = pixel_count * @as(usize, actual_channels);
        const pixel_slice: []const u8 = pixels[0..pixel_data_size];

        // Copy pixel data for main thread (freed in GPU upload job)
        const pixel_copy = std.heap.page_allocator.dupe(u8, pixel_slice) catch {
            logger.err("Failed to allocate pixel buffer for async texture upload", .{});
            if (args.callback) |cb| cb(INVALID_TEXTURE_ID);
            return;
        };

        // 3. Submit GPU upload job to main thread
        const upload_args = AsyncUploadArgs{
            .path_copy = std.heap.page_allocator.dupe(u8, args.path_copy) catch {
                std.heap.page_allocator.free(pixel_copy);
                if (args.callback) |cb| cb(INVALID_TEXTURE_ID);
                return;
            },
            .width = @intCast(width),
            .height = @intCast(height),
            .channel_count = actual_channels,
            .has_transparency = has_transparency,
            .pixels = pixel_copy,
            .callback = args.callback,
        };

        const jobs_sys = context.get().jobs orelse {
            std.heap.page_allocator.free(pixel_copy);
            std.heap.page_allocator.free(upload_args.path_copy);
            logger.err("Job system not available for GPU upload", .{});
            if (args.callback) |cb| cb(INVALID_TEXTURE_ID);
            return;
        };

        _ = jobs_sys.submitMainThread(asyncUploadJob, .{upload_args}) catch {
            std.heap.page_allocator.free(pixel_copy);
            std.heap.page_allocator.free(upload_args.path_copy);
            logger.err("Failed to submit GPU upload job", .{});
            if (args.callback) |cb| cb(INVALID_TEXTURE_ID);
        };
    }

    /// Arguments for GPU upload job
    const AsyncUploadArgs = struct {
        path_copy: []const u8,
        width: u32,
        height: u32,
        channel_count: u8,
        has_transparency: bool,
        pixels: []const u8,
        callback: ?*const fn (u32) void,
    };

    /// Main-thread job that uploads texture to GPU
    fn asyncUploadJob(args: AsyncUploadArgs) void {
        defer std.heap.page_allocator.free(args.pixels);
        defer std.heap.page_allocator.free(args.path_copy);

        const sys = getSystem() orelse {
            logger.err("Texture system not available in GPU upload job", .{});
            if (args.callback) |cb| cb(INVALID_TEXTURE_ID);
            return;
        };

        // Create GPU texture
        const texture_id = sys.createFromPixelsInternal(
            args.width,
            args.height,
            args.channel_count,
            args.has_transparency,
            args.pixels,
            args.path_copy,
        );

        if (texture_id == INVALID_TEXTURE_ID) {
            logger.err("Failed to create GPU texture (async): {s}", .{args.path_copy});
            if (args.callback) |cb| cb(INVALID_TEXTURE_ID);
            return;
        }

        // Add to path cache
        const path_for_cache = std.heap.page_allocator.dupe(u8, args.path_copy) catch {
            logger.warn("Failed to allocate path for cache (async): {s}", .{args.path_copy});
            if (args.callback) |cb| cb(texture_id);
            return;
        };

        const idx = texture_id - 1;
        sys.textures[idx].path = path_for_cache;
        sys.path_lookup.put(path_for_cache, texture_id) catch {
            logger.warn("Failed to add texture to cache (async): {s}", .{args.path_copy});
            std.heap.page_allocator.free(path_for_cache);
            sys.textures[idx].path = null;
        };

        logger.info("Texture loaded asynchronously: {s} (id={})", .{ args.path_copy, texture_id });

        // Invoke callback
        if (args.callback) |cb| {
            cb(texture_id);
        }
    }
};

/// Get the texture system instance
pub fn getSystem() ?*TextureSystem {
    return context.get().texture;
}

// ========== Public API (Used by Resource Manager) ==========

/// Load texture synchronously (used by Resource Manager)
pub fn loadFromFile(path: []const u8) u32 {
    const sys = getSystem() orelse return INVALID_TEXTURE_ID;
    return sys.loadFromFile(path);
}

/// Load texture asynchronously (used by Resource Manager)
pub fn loadFromFileAsync(
    path: []const u8,
    options: LoadOptions,
    callback: ?*const fn (u32) void,
) !jobs.JobHandle {
    const sys = getSystem() orelse return error.SystemNotInitialized;
    return sys.loadFromFileAsync(path, options, callback);
}

// ========== Internal/Legacy API ==========

pub fn getTexture(id: u32) ?*resource_types.Texture {
    const sys = getSystem() orelse return null;
    return sys.getTexture(id);
}

pub fn getDefaultTexture() ?*resource_types.Texture {
    const sys = getSystem() orelse return null;
    return sys.getDefaultTexture();
}

pub fn release(id: u32) void {
    if (getSystem()) |sys| {
        sys.release(id);
    }
}

pub fn bind(id: u32) void {
    if (getSystem()) |sys| {
        sys.bind(id);
    }
}
