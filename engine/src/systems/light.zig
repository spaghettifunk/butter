//! Light System
//!
//! Manages lights in the scene. Owned by RendererSystem.

const std = @import("std");
const math = @import("../math/math.zig");
const math_types = @import("../math/types.zig");
const logger = @import("../core/logging.zig");

// Maximum number of lights supported in the scene (for now just one directional light in UBO)
// Future: Support multiple lights via SSBO or larger UBO
const MAX_LIGHTS = 16;

pub const LightType = enum {
    directional,
    point,
    spot,
};

pub const ShadowType = enum {
    none,
    hard,
    soft,
};

pub const Light = struct {
    id: u32,
    type: LightType,
    shadow_type: ShadowType = .none,
    position: [3]f32 = .{ 0, 0, 0 },
    direction: [3]f32 = .{ 0, -1, 0 },
    color: [3]f32 = .{ 1, 1, 1 },
    intensity: f32 = 1.0,
    range: f32 = 10.0, // For point/spot lights
    enabled: bool = true,
};

pub const LightSystem = struct {
    lights: std.ArrayListUnmanaged(Light),
    allocator: std.mem.Allocator,

    // Main directional light that affects GlobalUBO directly
    main_light_index: ?usize = null,

    // Ambient light settings
    ambient_color: [4]f32 = .{ 0.1, 0.1, 0.1, 1.0 },

    pub fn init(allocator: std.mem.Allocator) LightSystem {
        var self = LightSystem{
            .lights = .empty,
            .allocator = allocator,
        };

        // Create default main light
        _ = self.createLight(.{
            .type = .directional,
            .direction = .{ -0.5, -1.0, -0.3 }, // angled down
            .color = .{ 1.0, 1.0, 1.0 },
            .intensity = 1.0,
        }) catch {
            logger.warn("Failed to create default light", .{});
        };

        // Set as main light
        self.main_light_index = 0;

        logger.info("Light system initialized", .{});
        return self;
    }

    pub fn deinit(self: *LightSystem) void {
        self.lights.deinit(self.allocator);
    }

    pub fn createLight(self: *LightSystem, config: struct {
        type: LightType = .directional,
        position: [3]f32 = .{ 0, 0, 0 },
        direction: [3]f32 = .{ 0, -1, 0 },
        color: [3]f32 = .{ 1, 1, 1 },
        intensity: f32 = 1.0,
        range: f32 = 10.0,
    }) !u32 {
        const id = @as(u32, @intCast(self.lights.items.len)) + 1;

        var dir_vec = math_types.Vec3{ .elements = config.direction };
        math.vec3Normalize(&dir_vec);
        const dir = dir_vec.elements;

        try self.lights.append(self.allocator, .{
            .id = id,
            .type = config.type,
            .position = config.position,
            .direction = dir,
            .color = config.color,
            .intensity = config.intensity,
            .range = config.range,
        });

        return id;
    }

    pub fn getLight(self: *LightSystem, index: usize) ?*Light {
        if (index >= self.lights.items.len) return null;
        return &self.lights.items[index];
    }

    pub fn getLightById(self: *LightSystem, id: u32) ?*Light {
        for (self.lights.items) |*light| {
            if (light.id == id) return light;
        }
        return null;
    }

    pub fn setMainLight(self: *LightSystem, index: usize) void {
        if (index < self.lights.items.len) {
            self.main_light_index = index;
        }
    }

    pub fn getMainLight(self: *LightSystem) ?*Light {
        if (self.main_light_index) |idx| {
            if (idx < self.lights.items.len) {
                return &self.lights.items[idx];
            }
        }
        return null;
    }
};
