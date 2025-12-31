//! Renderer subsystem - provides the backend interface and types.
//!
//! In Zig, instead of using function pointers like in C, we use a tagged union
//! combined with a vtable pattern. This gives us compile-time type safety
//! while maintaining the same runtime flexibility.

const std = @import("std");
const context = @import("../context.zig");
const logger = @import("../core/logging.zig");
const math_types = @import("../math/types.zig");
const math = @import("../math/math.zig");
const resource_types = @import("../resources/types.zig");
const geometry_types = @import("../systems/geometry.zig");

const builtin = @import("builtin");

// Backend implementations
pub const vulkan = @import("vulkan/backend.zig");
pub const metal = @import("metal/backend.zig");

// Render graph system
pub const render_graph = @import("render_graph/mod.zig");

/// Supported renderer backend types
pub const BackendType = enum {
    vulkan,
    metal,
    directx,
};

/// Render packet passed each frame
pub const RenderPacket = struct {
    delta_time: f32,
};

/// Global uniform buffer object containing frame-wide rendering data.
/// This is the shared UBO structure used by all backends.
/// Layout matches std140 for GLSL/MSL compatibility.
/// Total size: 352 bytes (extended for shadow mapping)
pub const GlobalUBO = extern struct {
    // Matrices (128 bytes) - projection and view only, model moved to push constants
    projection: math_types.Mat4,
    view: math_types.Mat4,

    // Shadow mapping matrices (128 bytes)
    light_space_matrix: math_types.Mat4,
    shadow_projection: math_types.Mat4,

    // Camera data (16 bytes, padded to vec4)
    camera_position: [3]f32 = .{ 0, 0, 0 },
    _pad0: f32 = 0,

    // Light data (32 bytes)
    light_direction: [3]f32 = .{ 0.5, -1.0, 0.3 },
    light_intensity: f32 = 1.0,
    light_color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    shadow_map_size: f32 = 2048.0,

    // Screen/viewport data (16 bytes)
    screen_size: [2]f32 = .{ 1280, 720 },
    near_plane: f32 = 0.1,
    far_plane: f32 = 1000.0,

    // Time data (16 bytes)
    time: f32 = 0,
    delta_time: f32 = 0,
    frame_count: u32 = 0,
    _pad1: f32 = 0,

    // Ambient lighting (16 bytes)
    ambient_color: [4]f32 = .{ 0.1, 0.1, 0.1, 1.0 },

    /// Create a default GlobalUBO with identity matrices
    pub fn init() GlobalUBO {
        return GlobalUBO{
            .projection = math.mat4Identity(),
            .view = math.mat4Identity(),
            .light_space_matrix = math.mat4Identity(),
            .shadow_projection = math.mat4Identity(),
        };
    }
};

/// Backend interface - defines what every backend must implement.
/// This replaces the C function pointer approach with Zig's interface pattern.
pub const Backend = union(BackendType) {
    vulkan: vulkan.VulkanBackend,
    metal: metal.MetalBackend,
    directx: void, // Not implemented

    pub fn initialize(self: *Backend, application_name: []const u8) bool {
        return switch (self.*) {
            .vulkan => |*v| v.initialize(application_name),
            .metal => |*m| m.initialize(application_name),
            else => {
                logger.err("Backend not implemented", .{});
                return false;
            },
        };
    }

    pub fn shutdown(self: *Backend) void {
        switch (self.*) {
            .vulkan => |*v| v.shutdown(),
            .metal => |*m| m.shutdown(),
            else => {},
        }
    }

    pub fn resized(self: *Backend, width: u16, height: u16) void {
        switch (self.*) {
            .vulkan => |*v| v.resized(width, height),
            .metal => |*m| m.resized(width, height),
            else => {},
        }
    }

    pub fn beginFrame(self: *Backend, delta_time: f32) bool {
        return switch (self.*) {
            .vulkan => |*v| v.beginFrame(delta_time),
            .metal => |*m| m.beginFrame(delta_time),
            else => false,
        };
    }

    pub fn endFrame(self: *Backend, delta_time: f32) bool {
        return switch (self.*) {
            .vulkan => |*v| v.endFrame(delta_time),
            .metal => |*m| m.endFrame(delta_time),
            else => false,
        };
    }

    pub fn createTexture(
        self: *Backend,
        texture: *resource_types.Texture,
        width: u32,
        height: u32,
        channel_count: u8,
        has_transparency: bool,
        pixels: []const u8,
    ) bool {
        return switch (self.*) {
            .vulkan => |*v| v.createTexture(texture, width, height, channel_count, has_transparency, pixels),
            .metal => |*m| m.createTexture(texture, width, height, channel_count, has_transparency, pixels),
            else => {
                logger.err("createTexture not implemented for this backend", .{});
                return false;
            },
        };
    }

    pub fn destroyTexture(self: *Backend, texture: *resource_types.Texture) void {
        switch (self.*) {
            .vulkan => |*v| v.destroyTexture(texture),
            .metal => |*m| m.destroyTexture(texture),
            else => {},
        }
    }

    pub fn bindTexture(self: *Backend, texture: ?*const resource_types.Texture) void {
        switch (self.*) {
            .vulkan => |*v| v.bindTexture(texture),
            .metal => |*m| m.bindTexture(texture),
            else => {},
        }
    }

    /// Update the global uniform buffer with frame data.
    /// This is called by the renderer system at the start of each frame.
    pub fn updateUBO(self: *Backend, ubo: *const GlobalUBO) void {
        switch (self.*) {
            .vulkan => |*v| v.updateUBO(ubo),
            .metal => |*m| m.updateUBO(ubo),
            else => {},
        }
    }

    /// Draw geometry using its GPU buffers with a model matrix
    pub fn drawGeometry(self: *Backend, geo: *const geometry_types.Geometry, model_matrix: *const math_types.Mat4) void {
        switch (self.*) {
            .vulkan => |*v| v.drawGeometry(geo, model_matrix),
            .metal => |*m| m.drawGeometry(geo, model_matrix),
            else => {},
        }
    }

    /// Bind geometry buffers for drawing (without issuing draw call)
    pub fn bindGeometry(self: *Backend, geo: *const geometry_types.Geometry) void {
        switch (self.*) {
            .vulkan => |*v| v.bindGeometry(geo),
            .metal => |*m| m.bindGeometry(geo),
            else => {},
        }
    }

    /// Get the current command buffer handle for render graph passes (Vulkan only)
    /// Returns null if not currently recording a frame or not Vulkan backend
    pub fn getCurrentCommandBuffer(self: *Backend) ?*anyopaque {
        return switch (self.*) {
            .vulkan => |*v| if (v.getCurrentCommandBuffer()) |cmd| @ptrCast(cmd) else null,
            else => null,
        };
    }

    /// Get the current frame index
    pub fn getCurrentFrame(self: *Backend) u32 {
        return switch (self.*) {
            .vulkan => |*v| v.getCurrentFrame(),
            .metal => |*m| m.getCurrentFrame(),
            else => 0,
        };
    }

    /// Get the current image/drawable index
    pub fn getImageIndex(self: *Backend) u32 {
        return switch (self.*) {
            .vulkan => |*v| v.getImageIndex(),
            .metal => |*m| m.getImageIndex(),
            else => 0,
        };
    }

    // =========================================================================
    // ImGui Backend Interface
    // =========================================================================

    /// Initialize ImGui backends (GLFW + renderer-specific backend)
    pub fn initImGui(self: *Backend) bool {
        return switch (self.*) {
            .vulkan => |*v| v.initImGui(),
            .metal => |*m| m.initImGui(),
            else => false,
        };
    }

    /// Shutdown ImGui backends
    pub fn shutdownImGui(self: *Backend) void {
        switch (self.*) {
            .vulkan => |*v| v.shutdownImGui(),
            .metal => |*m| m.shutdownImGui(),
            else => {},
        }
    }

    /// Begin ImGui frame (called before ImGui::NewFrame)
    pub fn beginImGuiFrame(self: *Backend) void {
        switch (self.*) {
            .vulkan => |*v| v.beginImGuiFrame(),
            .metal => |*m| m.beginImGuiFrame(),
            else => {},
        }
    }

    /// Render ImGui draw data
    pub fn renderImGui(self: *Backend, draw_data: ?*anyopaque) void {
        switch (self.*) {
            .vulkan => |*v| v.renderImGui(draw_data),
            .metal => |*m| m.renderImGui(draw_data),
            else => {},
        }
    }
};

/// The renderer system state
pub const RendererSystem = struct {
    backend: Backend,
    frame_number: u64,
    projection: math_types.Mat4,
    view: math_types.Mat4,
    near_clip: f32,
    far_clip: f32,
    // Camera state for game control
    camera_position: [3]f32 = .{ 0.0, 0.0, 3.0 },
    camera_view_matrix: ?math_types.Mat4 = null, // If set, use this directly instead of computing from yaw/pitch
    camera_yaw: f32 = 0.0, // Rotation around Y axis (left/right) - only used if camera_view_matrix is null
    camera_pitch: f32 = 0.0, // Rotation around X axis (up/down) - only used if camera_view_matrix is null
    // Time tracking for UBO
    total_time: f32 = 0.0,
    // Framebuffer dimensions
    framebuffer_width: u32 = 1280,
    framebuffer_height: u32 = 720,

    /// Initialize the renderer system (called by engine at startup)
    pub fn initialize(backend_type: BackendType, application_name: []const u8) bool {
        instance = RendererSystem{
            .backend = switch (backend_type) {
                .vulkan => .{ .vulkan = vulkan.VulkanBackend{} },
                .metal => .{ .metal = metal.MetalBackend{} },
                else => {
                    logger.err("Unsupported backend type", .{});
                    return false;
                },
            },
            .frame_number = 0,
            .near_clip = 0.1,
            .far_clip = 1000.0,
            .projection = math.mat4Identity(),
            .view = math.mat4Identity(),
        };

        instance.projection = math.mat4Perspective(math.degToRad(45.0), 1280.0 / 720.0, instance.near_clip, instance.far_clip);

        if (!instance.backend.initialize(application_name)) {
            logger.err("Renderer backend failed to initialize. Shutting down.", .{});
            return false;
        }

        instance.view = math.mat4Translation(0, 0, -30.0);
        instance.view = math.mat4Inverse(instance.view);

        // Register with the shared context
        context.get().renderer = &instance;
        logger.info("Renderer system initialized.", .{});
        return true;
    }

    /// Shutdown the renderer system
    pub fn shutdown() void {
        if (context.get().renderer) |sys| {
            sys.backend.shutdown();
        }
        context.get().renderer = null;
        logger.info("Renderer system shutdown.", .{});
    }

    pub fn beginFrame(self: *RendererSystem, delta_time: f32) bool {
        // Update time tracking
        self.total_time += delta_time;

        // Use provided view matrix if available, otherwise compute from yaw/pitch
        if (self.camera_view_matrix) |view_matrix| {
            self.view = view_matrix;
        } else {
            // Fallback: calculate view matrix from camera state (legacy path)
            const translation = math.mat4Translation(-self.camera_position[0], -self.camera_position[1], -self.camera_position[2]);
            const rotation_y = math.mat4RotationY(-self.camera_yaw);
            const rotation_x = math.mat4RotationX(-self.camera_pitch);
            // View = RotX * RotY * Translation (order matters!)
            self.view = math.mat4Mul(math.mat4Mul(rotation_x, rotation_y), translation);
        }

        // Begin the frame on the backend (sets up command buffers, etc.)
        if (!self.backend.beginFrame(delta_time)) {
            return false;
        }

        // Calculate and upload UBO data
        var ubo = GlobalUBO.init();
        ubo.projection = self.projection;
        ubo.view = self.view;
        ubo.camera_position = self.camera_position;
        ubo.screen_size = .{
            @floatFromInt(self.framebuffer_width),
            @floatFromInt(self.framebuffer_height),
        };
        ubo.near_plane = self.near_clip;
        ubo.far_plane = self.far_clip;
        ubo.time = self.total_time;
        ubo.delta_time = delta_time;
        ubo.frame_count = @intCast(self.frame_number);

        self.backend.updateUBO(&ubo);
        return true;
    }

    pub fn endFrame(self: *RendererSystem, delta_time: f32) bool {
        const result = self.backend.endFrame(delta_time);
        self.frame_number += 1;
        return result;
    }

    pub fn onResized(self: *RendererSystem, width: u16, height: u16) void {
        // Store framebuffer dimensions for UBO
        self.framebuffer_width = width;
        self.framebuffer_height = height;

        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        const aspect = if (h > 0) w / h else 1.0;
        self.projection = math.mat4Perspective(math.degToRad(45.0), aspect, self.near_clip, self.far_clip);

        self.backend.resized(width, height);
    }

    /// Draw a complete frame
    pub fn drawFrame(self: *RendererSystem, packet: *const RenderPacket) bool {
        // If the begin frame returned successfully, mid-frame operations may continue.
        if (self.beginFrame(packet.delta_time)) {
            // End the frame. If this fails, it is likely unrecoverable.
            const result = self.endFrame(packet.delta_time);

            if (!result) {
                logger.err("renderer end_frame failed. Application shutting down...", .{});
                return false;
            }
        }

        return true;
    }

    /// Create a texture from raw pixel data
    pub fn createTexture(
        self: *RendererSystem,
        texture: *resource_types.Texture,
        width: u32,
        height: u32,
        channel_count: u8,
        has_transparency: bool,
        pixels: []const u8,
    ) bool {
        return self.backend.createTexture(texture, width, height, channel_count, has_transparency, pixels);
    }

    /// Destroy a texture and free all associated resources
    pub fn destroyTexture(self: *RendererSystem, texture: *resource_types.Texture) void {
        self.backend.destroyTexture(texture);
    }

    /// Bind a texture for rendering. Pass null to use the default white texture.
    pub fn bindTexture(self: *RendererSystem, texture: ?*const resource_types.Texture) void {
        self.backend.bindTexture(texture);
    }

    /// Draw geometry using its GPU buffers with a model matrix
    pub fn drawGeometry(self: *RendererSystem, geo: *const geometry_types.Geometry, model_matrix: *const math_types.Mat4) void {
        self.backend.drawGeometry(geo, model_matrix);
    }

    /// Bind geometry buffers for drawing (without issuing draw call)
    pub fn bindGeometry(self: *RendererSystem, geo: *const geometry_types.Geometry) void {
        self.backend.bindGeometry(geo);
    }
};

// Private instance storage (only valid in engine executable)
var instance: RendererSystem = undefined;

/// Get the renderer system instance (works from engine or game)
pub fn getSystem() ?*RendererSystem {
    return context.get().renderer;
}
