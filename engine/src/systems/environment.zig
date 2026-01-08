//! Environment System
//!
//! Manages Image-Based Lighting (IBL) resources for PBR rendering.
//! Provides ambient lighting and reflections through environment maps.

const std = @import("std");
const context = @import("../context.zig");
const logger = @import("../core/logging.zig");
const resource_types = @import("../resources/types.zig");
const texture_system = @import("texture.zig");
const renderer = @import("../renderer/renderer.zig");

/// IBL texture set for PBR rendering
pub const IBLTextures = struct {
    /// Irradiance cubemap (32x32) for diffuse IBL
    irradiance_map_id: u32,

    /// Prefiltered environment cubemap (512x512 with 5 mip levels) for specular IBL
    prefiltered_map_id: u32,

    /// BRDF lookup table (512x512 2D texture, R16G16 format)
    brdf_lut_id: u32,
};

/// Environment map source
pub const EnvironmentSource = enum {
    /// Procedurally generated gradient sky
    procedural,
    /// Loaded from HDR file (.hdr equirectangular)
    hdr_file,
};

/// Environment configuration
pub const EnvironmentConfig = struct {
    source: EnvironmentSource = .procedural,
    path: ?[]const u8 = null, // Path to .hdr file if source is .hdr_file
    intensity: f32 = 1.0, // IBL intensity multiplier
};

// Private instance storage
var instance: ?*EnvironmentSystem = null;

pub const EnvironmentSystem = struct {
    allocator: std.mem.Allocator,

    /// Current IBL textures
    ibl_textures: IBLTextures,

    /// Current environment configuration
    config: EnvironmentConfig,

    /// Whether the system has been initialized
    initialized: bool = false,

    /// Initialize the environment system with default procedural environment
    pub fn init(allocator: std.mem.Allocator) !*EnvironmentSystem {
        const self = try allocator.create(EnvironmentSystem);
        errdefer allocator.destroy(self);

        self.* = EnvironmentSystem{
            .allocator = allocator,
            .ibl_textures = undefined,
            .config = .{},
            .initialized = false,
        };

        // Create default IBL textures
        if (!self.createDefaultEnvironment()) {
            logger.err("Failed to create default environment", .{});
            return error.EnvironmentInitFailed;
        }

        self.initialized = true;
        instance = self;

        // Register with engine context
        context.get().environment = self;
        logger.info("Environment system initialized with default procedural environment", .{});

        return self;
    }

    /// Shutdown the environment system
    pub fn deinit(self: *EnvironmentSystem) void {
        if (!self.initialized) return;

        // Release IBL textures
        const tex_sys = texture_system.getSystem() orelse {
            logger.warn("Texture system not available during environment shutdown", .{});
            self.allocator.destroy(self);
            return;
        };

        tex_sys.release(self.ibl_textures.irradiance_map_id);
        tex_sys.release(self.ibl_textures.prefiltered_map_id);
        tex_sys.release(self.ibl_textures.brdf_lut_id);

        context.get().environment = null;
        instance = null;
        self.initialized = false;

        self.allocator.destroy(self);
        logger.info("Environment system shutdown", .{});
    }

    /// Get current IBL textures for rendering
    pub fn getIBLTextures(self: *EnvironmentSystem) *const IBLTextures {
        return &self.ibl_textures;
    }

    /// Load environment from HDR file
    /// TODO: Implement HDR loading in future phase
    pub fn loadFromHDR(self: *EnvironmentSystem, path: []const u8) !void {
        _ = self;
        _ = path;
        logger.warn("HDR environment loading not yet implemented. Using default environment.", .{});
        return error.NotImplemented;
    }

    /// Set IBL intensity multiplier
    pub fn setIntensity(self: *EnvironmentSystem, intensity: f32) void {
        self.config.intensity = intensity;
    }

    /// Get IBL intensity
    pub fn getIntensity(self: *EnvironmentSystem) f32 {
        return self.config.intensity;
    }

    // ========== Private Implementation ==========

    /// Create default procedural environment
    /// Generates simple gradient sky and default IBL textures
    fn createDefaultEnvironment(self: *EnvironmentSystem) bool {
        const tex_sys = texture_system.getSystem() orelse {
            logger.err("Texture system not available for environment creation", .{});
            return false;
        };

        // Create default irradiance map (32x32 single-color cubemap)
        // For now, we'll use a placeholder approach: create a simple solid color texture
        // In a full implementation, this would be a proper cubemap
        // Using neutral gray with moderate intensity (0.6) for ambient lighting
        const irradiance_id = self.createSolidColorTexture(tex_sys, 32, 32, .{ 0.6, 0.6, 0.6, 1.0 }, "default_irradiance");
        if (irradiance_id == texture_system.INVALID_TEXTURE_ID) {
            logger.err("Failed to create default irradiance map", .{});
            return false;
        }

        // Create default prefiltered map (512x512 cubemap)
        // Using neutral gray with moderate intensity (0.6) for specular reflections
        const prefiltered_id = self.createSolidColorTexture(tex_sys, 512, 512, .{ 0.6, 0.6, 0.6, 1.0 }, "default_prefiltered");
        if (prefiltered_id == texture_system.INVALID_TEXTURE_ID) {
            tex_sys.release(irradiance_id);
            logger.err("Failed to create default prefiltered map", .{});
            return false;
        }

        // Create default BRDF LUT (512x512 2D texture)
        const brdf_lut_id = self.createDefaultBRDFLUT(tex_sys);
        if (brdf_lut_id == texture_system.INVALID_TEXTURE_ID) {
            tex_sys.release(irradiance_id);
            tex_sys.release(prefiltered_id);
            logger.err("Failed to create default BRDF LUT", .{});
            return false;
        }

        self.ibl_textures = .{
            .irradiance_map_id = irradiance_id,
            .prefiltered_map_id = prefiltered_id,
            .brdf_lut_id = brdf_lut_id,
        };

        self.config = .{
            .source = .procedural,
            .intensity = 1.0,
        };

        logger.info("Default environment created (irradiance={}, prefiltered={}, brdf_lut={})", .{
            irradiance_id,
            prefiltered_id,
            brdf_lut_id,
        });

        return true;
    }

    /// Create a solid color texture (placeholder for cubemaps)
    fn createSolidColorTexture(
        self: *EnvironmentSystem,
        tex_sys: *texture_system.TextureSystem,
        width: u32,
        height: u32,
        color: [4]f32,
        debug_name: []const u8,
    ) u32 {
        // Convert float color to u8
        const r: u8 = @intFromFloat(@max(0.0, @min(255.0, color[0] * 255.0)));
        const g: u8 = @intFromFloat(@max(0.0, @min(255.0, color[1] * 255.0)));
        const b: u8 = @intFromFloat(@max(0.0, @min(255.0, color[2] * 255.0)));
        const a: u8 = @intFromFloat(@max(0.0, @min(255.0, color[3] * 255.0)));

        // Create pixel buffer
        const pixel_count = width * height;
        const buffer_size = pixel_count * 4;
        const pixels = self.allocator.alloc(u8, buffer_size) catch {
            logger.err("Failed to allocate pixel buffer for {s}", .{debug_name});
            return texture_system.INVALID_TEXTURE_ID;
        };
        defer self.allocator.free(pixels);

        // Fill with solid color
        var i: usize = 0;
        while (i < pixel_count) : (i += 1) {
            const idx = i * 4;
            pixels[idx + 0] = r;
            pixels[idx + 1] = g;
            pixels[idx + 2] = b;
            pixels[idx + 3] = a;
        }

        return tex_sys.createFromPixels(width, height, 4, true, pixels);
    }

    /// Create default BRDF lookup table
    /// This is a simplified version. For production, use a pre-generated LUT texture
    fn createDefaultBRDFLUT(self: *EnvironmentSystem, tex_sys: *texture_system.TextureSystem) u32 {
        const size: u32 = 512;
        const pixel_count = size * size;
        const buffer_size = pixel_count * 4; // RGBA8 format

        const pixels = self.allocator.alloc(u8, buffer_size) catch {
            logger.err("Failed to allocate BRDF LUT buffer", .{});
            return texture_system.INVALID_TEXTURE_ID;
        };
        defer self.allocator.free(pixels);

        // Generate a simple approximation of BRDF LUT
        // X axis: NdotV (roughness), Y axis: roughness
        // R channel: scale, G channel: bias
        var y: u32 = 0;
        while (y < size) : (y += 1) {
            var x: u32 = 0;
            while (x < size) : (x += 1) {
                const idx = (y * size + x) * 4;

                // Simple approximation (not physically accurate, but good enough for default)
                const roughness: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(size));
                const ndotv: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(size));

                // Very simple approximation
                const scale = (1.0 - roughness) * ndotv;
                const bias = roughness * (1.0 - ndotv) * 0.5;

                pixels[idx + 0] = @intFromFloat(@max(0.0, @min(255.0, scale * 255.0)));
                pixels[idx + 1] = @intFromFloat(@max(0.0, @min(255.0, bias * 255.0)));
                pixels[idx + 2] = 0;
                pixels[idx + 3] = 255;
            }
        }

        logger.info("Generated default BRDF LUT ({}x{})", .{ size, size });
        return tex_sys.createFromPixels(size, size, 4, false, pixels);
    }
};

/// Get the environment system instance
pub fn getSystem() ?*EnvironmentSystem {
    return instance;
}

/// Initialize the environment system (public API)
pub fn initialize(allocator: std.mem.Allocator) !void {
    _ = try EnvironmentSystem.init(allocator);
}

/// Shutdown the environment system (public API)
pub fn shutdown() void {
    if (getSystem()) |sys| {
        sys.deinit();
    }
}
