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
const light = @import("../systems/light.zig");

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
/// Total size: 496 bytes (128 mat + 16 cam + 32 dirlight + 16 count + 256 lights + 16 screen + 16 time + 16 ambient)
pub const GlobalUBO = extern struct {
    // Matrices (128 bytes) - projection and view only, model moved to push constants
    projection: math_types.Mat4,
    view: math_types.Mat4,

    // Camera data (16 bytes, padded to vec4)
    camera_position: [3]f32 = .{ 0, 0, 0 },
    _pad0: f32 = 0,

    // Directional light (32 bytes)
    dir_light_direction: [3]f32 = .{ 0.5, -1.0, 0.3 },
    dir_light_intensity: f32 = 1.0,
    dir_light_color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    dir_light_enabled: f32 = 1.0, // 1.0 = enabled, 0.0 = disabled

    // Point light count (16 bytes, vec4 aligned)
    point_light_count: u32 = 0,
    _pad_lights1: f32 = 0,
    _pad_lights2: f32 = 0,
    _pad_lights3: f32 = 0,

    // Point lights array (8 lights * 32 bytes = 256 bytes)
    // Each light uses 2 vec4s: [pos.xyz, range], [color.rgb, intensity]
    point_lights: [16][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** 16,

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
        };
    }
};

/// Shadow uniform buffer object containing shadow mapping data.
/// This is Set 0, Binding 1 in shaders (GlobalUBO is Set 0, Binding 0).
/// Layout matches std140 for GLSL/MSL compatibility.
/// Total size: 320 bytes (256 matrices + 16 splits + 48 params)
pub const ShadowUBO = extern struct {
    // Cascade view-projection matrices (4 cascades * 64 bytes = 256 bytes)
    cascade_view_proj: [4]math_types.Mat4,

    // Cascade split distances in view space (16 bytes, vec4 aligned)
    cascade_splits: [4]f32,

    // Shadow parameters (16 bytes)
    shadow_bias: f32 = 0.005,
    slope_bias: f32 = 0.01,
    pcf_samples: f32 = 16.0, // float for shader compatibility
    directional_shadow_enabled: f32 = 1.0, // 1.0 = enabled, 0.0 = disabled

    // Point light shadow enable flags (16 bytes)
    point_shadow_enabled: [4]f32 = [_]f32{0.0} ** 4, // One per point light

    // Point light shadow indices (16 bytes) - maps point light index to shadow map index
    point_shadow_indices: [4]f32 = [_]f32{0.0} ** 4,

    /// Create a default ShadowUBO with identity matrices
    pub fn init() ShadowUBO {
        return ShadowUBO{
            .cascade_view_proj = [_]math_types.Mat4{math.mat4Identity()} ** 4,
            .cascade_splits = [_]f32{0.0} ** 4,
        };
    }
};

/// Grid shader uniform buffer object
/// Matches the GLSL layout in Builtin.GridShader.frag.glsl (set=0, binding=1)
/// Using explicit floats instead of vec3 to ensure consistent memory layout
/// across Vulkan (std140) and Metal (packed) backends.
/// Total size: 96 bytes
pub const GridUBO = extern struct {
    camera_pos_x: f32, // offset 0
    camera_pos_y: f32, // offset 4
    camera_pos_z: f32, // offset 8
    grid_height: f32, // offset 12

    minor_spacing: f32, // offset 16
    major_spacing: f32, // offset 20
    fade_distance: f32, // offset 24
    _pad0: f32, // offset 28 - padding before vec4s

    minor_color: [4]f32, // offset 32
    major_color: [4]f32, // offset 48
    axis_x_color: [4]f32, // offset 64
    axis_z_color: [4]f32, // offset 80

    pub fn initDefault() GridUBO {
        return GridUBO{
            .camera_pos_x = 0,
            .camera_pos_y = 0,
            .camera_pos_z = 0,
            .grid_height = 0.0,
            .minor_spacing = 1.0,
            .major_spacing = 10.0,
            .fade_distance = 500.0, // Increased from 100 to reduce fading
            ._pad0 = 0,
            // Grid lines in black, axes in color
            .minor_color = .{ 0.0, 0.0, 0.0, 1.0 }, // Black
            .major_color = .{ 0.0, 0.0, 0.0, 1.0 }, // Black
            .axis_x_color = .{ 1.0, 0.0, 0.0, 1.0 }, // Red for X axis
            .axis_z_color = .{ 0.0, 0.0, 1.0, 1.0 }, // Blue for Z axis
        };
    }
};

/// Grid camera UBO (view-projection matrix only)
/// Matches the GLSL layout in Builtin.GridShader.vert.glsl (set=0, binding=0)
/// Total size: 64 bytes
pub const GridCameraUBO = extern struct {
    view_proj: math_types.Mat4,

    pub fn init() GridCameraUBO {
        return GridCameraUBO{
            .view_proj = math.mat4Identity(),
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

    pub fn createTextureCubemap(
        self: *Backend,
        texture: *resource_types.Texture,
        width: u32,
        height: u32,
        channel_count: u8,
        face_pixels: [6][]const u8,
    ) bool {
        return switch (self.*) {
            .vulkan => |*v| v.createTextureCubemap(texture, width, height, channel_count, face_pixels),
            .metal => {
                logger.err("createTextureCubemap not implemented for Metal backend", .{});
                return false;
            },
            else => {
                logger.err("createTextureCubemap not implemented for this backend", .{});
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

    pub fn bindSpecularTexture(self: *Backend, texture: ?*const resource_types.Texture) void {
        switch (self.*) {
            .vulkan => |*v| v.bindSpecularTexture(texture),
            .metal => |*m| m.bindSpecularTexture(texture),
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

    /// Draw mesh asset with submesh support and per-object material
    pub fn drawMeshAsset(self: *Backend, mesh: *const @import("../resources/mesh_asset_types.zig").MeshAsset, model_matrix: *const math_types.Mat4, material: ?*const resource_types.Material) void {
        switch (self.*) {
            .vulkan => |*v| v.drawMeshAsset(mesh, model_matrix, material),
            .metal => |*m| m.drawMeshAsset(mesh, model_matrix, material),
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

    // Light system
    light_system: ?light.LightSystem = null,

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

        // Initialize light system
        // Use page allocator for now as we don't have a specific one passed in
        instance.light_system = light.LightSystem.init(std.heap.page_allocator);

        // Register with the shared context
        context.get().renderer = &instance;
        logger.info("Renderer system initialized.", .{});
        return true;
    }

    /// Shutdown the renderer system
    pub fn shutdown() void {
        if (context.get().renderer) |sys| {
            if (sys.light_system) |*ls| {
                ls.deinit();
            }
            sys.backend.shutdown();
        }

        // Shutdown environment system
        const environment = @import("../systems/environment.zig");
        environment.shutdown();

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

        // Update light data from light system
        if (self.light_system) |*ls| {
            ubo.ambient_color = ls.ambient_color;

            // Reset light states
            ubo.dir_light_enabled = 0.0;
            ubo.point_light_count = 0;

            var point_light_count: u32 = 0;

            for (ls.lights.items) |*lght| {
                if (!lght.enabled) continue;

                switch (lght.type) {
                    .directional => {
                        if (ubo.dir_light_enabled < 0.5) { // First directional only
                            ubo.dir_light_direction = lght.direction;
                            ubo.dir_light_color = lght.color;
                            ubo.dir_light_intensity = lght.intensity;
                            ubo.dir_light_enabled = 1.0;
                        }
                    },
                    .point => {
                        if (point_light_count < 8) { // Support up to 8 point lights
                            const idx = point_light_count * 2;
                            // First vec4: position.xyz and range
                            ubo.point_lights[idx][0] = lght.position[0];
                            ubo.point_lights[idx][1] = lght.position[1];
                            ubo.point_lights[idx][2] = lght.position[2];
                            ubo.point_lights[idx][3] = lght.range;
                            // Second vec4: color.rgb and intensity
                            ubo.point_lights[idx + 1][0] = lght.color[0];
                            ubo.point_lights[idx + 1][1] = lght.color[1];
                            ubo.point_lights[idx + 1][2] = lght.color[2];
                            ubo.point_lights[idx + 1][3] = lght.intensity;

                            point_light_count += 1;
                        }
                    },
                    .spot => {}, // Not implemented yet
                }
            }

            ubo.point_light_count = point_light_count;
        }

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

    /// Create a cubemap texture from 6 face images
    pub fn createTextureCubemap(
        self: *RendererSystem,
        texture: *resource_types.Texture,
        width: u32,
        height: u32,
        channel_count: u8,
        face_pixels: [6][]const u8,
    ) bool {
        return self.backend.createTextureCubemap(texture, width, height, channel_count, face_pixels);
    }

    /// Set the skybox cubemap texture and enable skybox rendering
    pub fn setSkyboxCubemap(self: *RendererSystem, cubemap_texture: *resource_types.Texture) void {
        switch (self.backend) {
            .vulkan => |*v| v.setSkyboxCubemap(cubemap_texture),
            .metal => {},
            .directx => {},
        }
    }

    /// Disable skybox rendering
    pub fn disableSkybox(self: *RendererSystem) void {
        switch (self.backend) {
            .vulkan => |*v| v.disableSkybox(),
            .metal => {},
            .directx => {},
        }
    }

    /// Destroy a texture and free all associated resources
    pub fn destroyTexture(self: *RendererSystem, texture: *resource_types.Texture) void {
        self.backend.destroyTexture(texture);
    }

    /// Bind a texture for rendering. Pass null to use the default white texture.
    pub fn bindTexture(self: *RendererSystem, texture: ?*const resource_types.Texture) void {
        self.backend.bindTexture(texture);
    }

    /// Bind a specular texture for rendering
    pub fn bindSpecularTexture(self: *RendererSystem, texture: ?*const resource_types.Texture) void {
        self.backend.bindSpecularTexture(texture);
    }

    /// Draw geometry using its GPU buffers with a model matrix
    pub fn drawGeometry(self: *RendererSystem, geo: *const geometry_types.Geometry, model_matrix: *const math_types.Mat4) void {
        self.backend.drawGeometry(geo, model_matrix);
    }

    /// Bind geometry buffers for drawing (without issuing draw call)
    pub fn bindGeometry(self: *RendererSystem, geo: *const geometry_types.Geometry) void {
        self.backend.bindGeometry(geo);
    }

    /// Draw mesh asset with submesh support and per-object material
    pub fn drawMeshAsset(self: *RendererSystem, mesh: *const @import("../resources/mesh_asset_types.zig").MeshAsset, model_matrix: *const math_types.Mat4, material: ?*const resource_types.Material) void {
        self.backend.drawMeshAsset(mesh, model_matrix, material);
    }
};

// Private instance storage (only valid in engine executable)
var instance: RendererSystem = undefined;

/// Get the renderer system instance (works from engine or game)
pub fn getSystem() ?*RendererSystem {
    return context.get().renderer;
}
