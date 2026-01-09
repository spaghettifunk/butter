//! Vulkan Backend Implementation

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const vk_context = @import("context.zig");
const vk = vk_context.vk;
const device = @import("device.zig");
const swapchain = @import("swapchain.zig");
const renderpass = @import("renderpass.zig");
const command_buffer = @import("command_buffer.zig");
const shader = @import("shader.zig");
const pipeline = @import("pipeline.zig");
const buffer = @import("buffer.zig");
const texture = @import("texture.zig");
const image = @import("image.zig");
const descriptor = @import("descriptor.zig");
const logger = @import("../../core/logging.zig");
const engine_context = @import("../../context.zig");
const math = @import("../../math/math.zig");
const math_types = @import("../../math/types.zig");
const renderer = @import("../renderer.zig");
const resource_types = @import("../../resources/types.zig");
const texture_system = @import("../../systems/texture.zig");
const geometry_types = @import("../../systems/geometry.zig");

// GLFW import for surface creation (only used in backend, not exposed to game)
const glfw = @cImport({
    @cDefine("GLFW_INCLUDE_VULKAN", "1");
    @cInclude("GLFW/glfw3.h");
});

// Conditional ImGui C bindings - only include when ImGui is enabled
const imgui_glfw = if (build_options.enable_imgui) @cImport({
    @cInclude("dcimgui_impl_glfw.h");
}) else struct {};

const imgui_vulkan = if (build_options.enable_imgui) @cImport({
    @cInclude("dcimgui_impl_vulkan.h");
}) else struct {};

/// Vulkan backend state
pub const VulkanBackend = struct {
    context: vk_context.VulkanContext = .{},

    // ImGui state
    imgui_initialized: bool = false,
    imgui_descriptor_pool: vk.VkDescriptorPool = null,
    pending_imgui_draw_data: ?*anyopaque = null, // Deferred ImGui rendering

    pub fn initialize(self: *VulkanBackend, application_name: []const u8) bool {
        // TODO: custom allocator
        self.context.allocator = null;

        // Setup Vulkan instance
        var app_info: vk.VkApplicationInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = application_name.ptr,
            .applicationVersion = vk.VK_MAKE_VERSION(1, 0, 0),
            .pEngineName = "Butter Engine",
            .engineVersion = vk.VK_MAKE_VERSION(1, 0, 0),
            .apiVersion = vk.VK_API_VERSION_1_2,
        };

        // Build extensions list based on platform and debug mode
        var extensions: [16][*c]const u8 = undefined;
        var extension_count: u32 = 0;

        // Platform-specific extensions
        // VK_KHR_surface is required for all platforms
        extensions[extension_count] = "VK_KHR_surface";
        extension_count += 1;

        if (builtin.os.tag == .macos) {
            // macOS uses MoltenVK which requires portability enumeration and metal surface
            extensions[extension_count] = "VK_KHR_portability_enumeration";
            extension_count += 1;
            extensions[extension_count] = "VK_EXT_metal_surface";
            extension_count += 1;
        } else if (builtin.os.tag == .linux) {
            // Linux surface extensions (XCB is most common, but could also use Xlib or Wayland)
            extensions[extension_count] = "VK_KHR_xcb_surface";
            extension_count += 1;
        } else if (builtin.os.tag == .windows) {
            extensions[extension_count] = "VK_KHR_win32_surface";
            extension_count += 1;
        }

        // Debug extensions (only in debug builds)
        if (vk_context.enable_validation) {
            extensions[extension_count] = vk.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
            extension_count += 1;
            logger.debug("Debug extensions enabled.", .{});
        }

        // On macOS with MoltenVK, we need the portability enumeration flag
        const flags: u32 = if (builtin.os.tag == .macos)
            vk_context.VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR
        else
            0;

        // Validation layers (only in debug builds)
        var validation_layers: [1][*c]const u8 = undefined;
        var layer_count: u32 = 0;

        if (vk_context.enable_validation) {
            if (checkValidationLayerSupport()) {
                validation_layers[0] = "VK_LAYER_KHRONOS_validation";
                layer_count = 1;
                logger.info("Validation layers enabled.", .{});
            } else {
                logger.warn("Validation layers requested but not available!", .{});
            }
        }

        var create_info: vk.VkInstanceCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = flags,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = layer_count,
            .ppEnabledLayerNames = if (layer_count > 0) &validation_layers else null,
            .enabledExtensionCount = extension_count,
            .ppEnabledExtensionNames = if (extension_count > 0) &extensions else null,
        };

        const result = vk.vkCreateInstance(&create_info, self.context.allocator, &self.context.instance);
        if (result != vk.VK_SUCCESS) {
            logger.err("vkCreateInstance failed with result: {}", .{result});
            return false;
        }
        logger.info("Vulkan instance created.", .{});

        // Create debug messenger (only in debug builds)
        if (vk_context.enable_validation) {
            if (!self.createDebugMessenger()) {
                logger.warn("Failed to create debug messenger, continuing without it.", .{});
            }
        }

        // Create surface
        if (!self.createSurface()) {
            logger.err("Failed to create Vulkan surface.", .{});
            return false;
        }

        // Select physical device
        if (!device.selectPhysicalDevice(&self.context)) {
            logger.err("Failed to select a suitable physical device.", .{});
            return false;
        }

        // Create logical device and retrieve queues
        if (!device.createLogicalDevice(&self.context)) {
            logger.err("Failed to create logical device.", .{});
            return false;
        }

        // Get initial framebuffer size from window
        const window_ptr = engine_context.get().platform_window orelse {
            logger.err("No platform window available for framebuffer size.", .{});
            return false;
        };
        const window: *glfw.GLFWwindow = @ptrCast(@alignCast(window_ptr));
        var fb_width: c_int = 0;
        var fb_height: c_int = 0;
        glfw.glfwGetFramebufferSize(window, &fb_width, &fb_height);
        self.context.framebuffer_width = @intCast(fb_width);
        self.context.framebuffer_height = @intCast(fb_height);

        // Create swapchain
        if (!swapchain.create(
            &self.context,
            &self.context.swapchain,
            self.context.framebuffer_width,
            self.context.framebuffer_height,
        )) {
            logger.err("Failed to create swapchain.", .{});
            return false;
        }

        // Create main renderpass
        if (!renderpass.createMainRenderpass(&self.context, &self.context.main_renderpass)) {
            logger.err("Failed to create main renderpass.", .{});
            return false;
        }

        // Create swapchain framebuffers
        if (!swapchain.createFramebuffers(
            &self.context,
            &self.context.swapchain,
            self.context.main_renderpass.handle,
        )) {
            logger.err("Failed to create swapchain framebuffers.", .{});
            return false;
        }

        // Create graphics command pool
        if (!command_buffer.createGraphicsCommandPool(&self.context, &self.context.graphics_command_pool)) {
            logger.err("Failed to create graphics command pool.", .{});
            return false;
        }

        // Allocate graphics command buffers (one per swapchain image)
        if (!self.createCommandBuffers()) {
            logger.err("Failed to create command buffers.", .{});
            return false;
        }

        // Create synchronization objects
        if (!self.createSyncObjects()) {
            logger.err("Failed to create synchronization objects.", .{});
            return false;
        }

        // Create global uniform buffers (one per frame in flight)
        if (!self.createGlobalUniformBuffers()) {
            logger.err("Failed to create global uniform buffers.", .{});
            return false;
        }

        // TWO-TIER DESCRIPTOR ARCHITECTURE
        // Set 0 (Global): UBO only - bound once per frame
        // Set 1 (Material): Textures only - bound per draw call

        // Create global descriptor layout (Set 0: UBO only)
        if (!descriptor.createGlobalLayout(&self.context, &self.context.global_descriptor_state)) {
            logger.err("Failed to create global descriptor set layout.", .{});
            return false;
        }

        // Create global descriptor pool
        if (!descriptor.createGlobalPool(
            &self.context,
            &self.context.global_descriptor_state,
            self.context.swapchain.max_frames_in_flight,
        )) {
            logger.err("Failed to create global descriptor pool.", .{});
            return false;
        }

        // Create material descriptor layout (Set 1: textures only)
        if (!descriptor.createMaterialLayout(&self.context, &self.context.material_descriptor_state)) {
            logger.err("Failed to create material descriptor layout.", .{});
            return false;
        }

        // Create material descriptor pool (128 material descriptor sets)
        if (!descriptor.createMaterialPool(&self.context, &self.context.material_descriptor_state)) {
            logger.err("Failed to create material descriptor pool.", .{});
            return false;
        }

        // Allocate global descriptor sets
        if (!descriptor.allocateGlobalSets(
            &self.context,
            &self.context.global_descriptor_state,
            self.context.swapchain.max_frames_in_flight,
        )) {
            logger.err("Failed to allocate global descriptor sets.", .{});
            return false;
        }

        // Create shadow descriptor layout (Set 2: shadow maps)
        if (!descriptor.createShadowLayout(&self.context, &self.context.shadow_descriptor_state)) {
            logger.err("Failed to create shadow descriptor layout.", .{});
            return false;
        }

        // Create shadow descriptor pool
        if (!descriptor.createShadowPool(
            &self.context,
            &self.context.shadow_descriptor_state,
            self.context.swapchain.max_frames_in_flight,
        )) {
            logger.err("Failed to create shadow descriptor pool.", .{});
            return false;
        }

        // Allocate shadow descriptor sets
        if (!descriptor.allocateShadowSets(
            &self.context,
            &self.context.shadow_descriptor_state,
            self.context.swapchain.max_frames_in_flight,
        )) {
            logger.err("Failed to allocate shadow descriptor sets.", .{});
            return false;
        }

        // Initialize shadow system (create shadow maps, render pass, etc.)
        if (!self.initializeShadowSystem()) {
            logger.err("Failed to initialize shadow system.", .{});
            return false;
        }

        // Initialize skybox descriptor layout and pool
        if (!descriptor.createSkyboxLayout(&self.context, &self.context.skybox_descriptor_state)) {
            logger.err("Failed to create skybox descriptor layout", .{});
            return false;
        }

        if (!descriptor.createSkyboxPool(&self.context, &self.context.skybox_descriptor_state)) {
            logger.err("Failed to create skybox descriptor pool", .{});
            return false;
        }

        // Update descriptor sets with uniform buffer bindings
        self.updateDescriptorSets();

        // Load shaders
        if (!self.loadShaders()) {
            logger.err("Failed to load shaders.", .{});
            return false;
        }

        // Create graphics pipeline with three-tier descriptor layout (Set 0: UBO, Set 1: Material, Set 2: Shadow)
        if (!pipeline.createMaterialPipelineWithShadow(
            &self.context,
            &self.context.material_shader,
            self.context.global_descriptor_state.global_layout,
            self.context.material_descriptor_state.material_layout,
            self.context.shadow_descriptor_state.layout,
            self.context.main_renderpass.handle,
        )) {
            logger.err("Failed to create object shader pipeline.", .{});
            return false;
        }

        // Create shadow pipeline for shadow map rendering
        if (!pipeline.createShadowPipeline(
            &self.context,
            &self.context.shadow_pipeline,
            self.context.global_descriptor_state.global_layout,
            self.context.shadow_renderpass.handle,
        )) {
            logger.err("Failed to create shadow pipeline.", .{});
            return false;
        }

        // Create skybox pipeline
        // Only include the descriptor sets actually used by the skybox shaders
        const skybox_layouts = [_]vk.VkDescriptorSetLayout{
            self.context.global_descriptor_state.global_layout, // Set 0: Global UBO
            self.context.skybox_descriptor_state.layout, // Set 1: Skybox cubemap
        };

        if (!self.createSkyboxPipeline(&skybox_layouts)) {
            logger.err("Failed to create skybox pipeline", .{});
            return false;
        }

        // Initialize grid rendering (editor only)
        if (build_options.enable_editor) {
            if (!self.initializeGrid()) {
                logger.err("Failed to initialize grid rendering.", .{});
                return false;
            }
        }

        // Create default texture (with material descriptor set for two-tier architecture)
        if (!self.createDefaultTexture()) {
            logger.err("Failed to create default texture.", .{});
            return false;
        }

        logger.info("Vulkan renderer initialized successfully.", .{});
        return true;
    }

    pub fn shutdown(self: *VulkanBackend) void {
        // Wait for device to be idle before cleanup
        if (self.context.device != null) {
            _ = vk.vkDeviceWaitIdle(self.context.device);
        }

        // Destroy default texture
        texture.destroy(&self.context, &self.context.default_texture);

        // Destroy grid resources (editor only)
        if (build_options.enable_editor) {
            self.cleanupGrid();
        }

        // Cleanup shadow system
        self.cleanupShadowSystem();

        // Destroy shadow pipeline
        pipeline.destroyShadowPipeline(&self.context, &self.context.shadow_pipeline);

        // Destroy skybox resources
        if (self.context.skybox_pipeline.handle != null) {
            vk.vkDestroyPipeline(self.context.device, self.context.skybox_pipeline.handle, self.context.allocator);
        }
        if (self.context.skybox_pipeline.layout != null) {
            vk.vkDestroyPipelineLayout(self.context.device, self.context.skybox_pipeline.layout, self.context.allocator);
        }
        descriptor.destroySkyboxState(&self.context, &self.context.skybox_descriptor_state);

        // Destroy graphics pipeline
        pipeline.destroyMaterialPipeline(&self.context, &self.context.material_shader);

        // Destroy shaders
        shader.destroy(&self.context, &self.context.material_shader.vertex_shader);
        shader.destroy(&self.context, &self.context.material_shader.fragment_shader);

        // Destroy descriptor pools (also frees descriptor sets)
        descriptor.destroyGlobalPool(&self.context, &self.context.global_descriptor_state);
        descriptor.destroyMaterialPool(&self.context, &self.context.material_descriptor_state);
        descriptor.destroyShadowPool(&self.context, &self.context.shadow_descriptor_state);

        // Destroy descriptor set layouts
        descriptor.destroyGlobalLayout(&self.context, &self.context.global_descriptor_state);
        descriptor.destroyMaterialLayout(&self.context, &self.context.material_descriptor_state);
        descriptor.destroyShadowLayout(&self.context, &self.context.shadow_descriptor_state);

        // Destroy global uniform buffers
        self.destroyGlobalUniformBuffers();

        // Destroy synchronization objects
        self.destroySyncObjects();

        // Free command buffers
        self.destroyCommandBuffers();

        // Destroy command pool
        command_buffer.destroyCommandPool(&self.context, &self.context.graphics_command_pool);

        // Destroy renderpass
        renderpass.destroy(&self.context, &self.context.main_renderpass);

        // Destroy swapchain
        swapchain.destroy(&self.context, &self.context.swapchain);

        // Destroy logical device (waits for device idle internally)
        device.destroyLogicalDevice(&self.context);

        // Destroy surface
        self.destroySurface();

        // Destroy debug messenger
        if (vk_context.enable_validation) {
            self.destroyDebugMessenger();
        }

        // Destroy instance
        if (self.context.instance) |instance| {
            logger.debug("Destroying Vulkan instance...", .{});
            vk.vkDestroyInstance(instance, self.context.allocator);
            self.context.instance = null;
        }
        logger.info("Vulkan renderer shutdown.", .{});
    }

    pub fn resized(self: *VulkanBackend, width: u16, height: u16) void {
        // Update framebuffer dimensions
        self.context.framebuffer_width = width;
        self.context.framebuffer_height = height;

        // Recreate swapchain with new dimensions
        if (width > 0 and height > 0) {
            // Wait for device to be idle before recreating
            if (self.context.device != null) {
                _ = vk.vkDeviceWaitIdle(self.context.device);
            }

            if (!swapchain.recreate(
                &self.context,
                &self.context.swapchain,
                width,
                height,
            )) {
                logger.err("Failed to recreate swapchain after resize.", .{});
                return;
            }

            // Recreate framebuffers for the new swapchain
            if (!swapchain.createFramebuffers(
                &self.context,
                &self.context.swapchain,
                self.context.main_renderpass.handle,
            )) {
                logger.err("Failed to recreate framebuffers after resize.", .{});
                return;
            }

            // Update renderpass render area
            renderpass.updateRenderArea(&self.context.main_renderpass, width, height);

            // Clear the recreating flag
            self.context.recreating_swapchain = false;
        }
    }

    pub fn beginFrame(self: *VulkanBackend, _: f32) bool {
        // Don't begin a frame if swapchain is being recreated
        if (self.context.recreating_swapchain) {
            return false;
        }

        const current_frame = self.context.current_frame;

        // Wait for the current frame's fence to be signaled
        if (!command_buffer.waitForFence(
            &self.context,
            self.context.in_flight_fences[current_frame],
            std.math.maxInt(u64),
        )) {
            logger.warn("In-flight fence wait failed.", .{});
            return false;
        }

        // Acquire the next swapchain image
        // Use image_index for semaphore to avoid reuse issues
        const acquire_result = swapchain.acquireNextImage(
            &self.context,
            &self.context.swapchain,
            std.math.maxInt(u64),
            self.context.image_available_semaphores[current_frame],
            null,
            &self.context.image_index,
        );

        if (acquire_result == vk.VK_ERROR_OUT_OF_DATE_KHR) {
            // Swapchain is out of date, needs recreation
            self.context.recreating_swapchain = true;
            return false;
        } else if (acquire_result != vk.VK_SUCCESS and acquire_result != vk.VK_SUBOPTIMAL_KHR) {
            logger.err("Failed to acquire swapchain image: {}", .{acquire_result});
            return false;
        }

        const image_index = self.context.image_index;

        // Check if a previous frame is still using this image
        if (self.context.images_in_flight[image_index] != null) {
            _ = command_buffer.waitForFence(
                &self.context,
                self.context.images_in_flight[image_index],
                std.math.maxInt(u64),
            );
        }

        // Mark the image as now being in use by this frame
        self.context.images_in_flight[image_index] = self.context.in_flight_fences[current_frame];

        // Reset the fence for this frame
        if (!command_buffer.resetFence(&self.context, self.context.in_flight_fences[current_frame])) {
            logger.err("Failed to reset in-flight fence.", .{});
            return false;
        }

        // Begin recording the command buffer
        const cmd_buffer = &self.context.graphics_command_buffers[image_index];
        if (!command_buffer.reset(cmd_buffer)) {
            logger.err("Failed to reset command buffer.", .{});
            return false;
        }

        if (!command_buffer.begin(cmd_buffer, false, false, false)) {
            logger.err("Failed to begin command buffer.", .{});
            return false;
        }

        // Begin the main renderpass
        renderpass.begin(
            &self.context.main_renderpass,
            cmd_buffer.handle,
            self.context.swapchain.framebuffers[image_index],
        );

        // Set up dynamic viewport and scissor AFTER beginning renderpass
        // Dynamic state must be set inside the renderpass
        // Use flipped viewport (negative height) for correct orientation with flipped clip space
        var viewport: vk.VkViewport = .{
            .x = 0.0,
            .y = @as(f32, @floatFromInt(self.context.framebuffer_height)),
            .width = @as(f32, @floatFromInt(self.context.framebuffer_width)),
            .height = -@as(f32, @floatFromInt(self.context.framebuffer_height)),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vk.vkCmdSetViewport(cmd_buffer.handle, 0, 1, &viewport);

        var scissor: vk.VkRect2D = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{
                .width = self.context.framebuffer_width,
                .height = self.context.framebuffer_height,
            },
        };
        vk.vkCmdSetScissor(cmd_buffer.handle, 0, 1, &scissor);

        // Render skybox if enabled (render first, so geometry draws on top)
        if (self.context.skybox_enabled) {
            self.renderSkybox(cmd_buffer.handle, image_index);
        }

        // Mark frame as in progress (for texture binding safety)
        self.context.frame_in_progress = true;

        return true;
    }

    pub fn endFrame(self: *VulkanBackend, delta_time: f32) bool {
        _ = delta_time;

        const image_index = self.context.image_index;
        const current_frame = self.context.current_frame;

        const cmd_buffer = &self.context.graphics_command_buffers[image_index];

        // Grid is now rendered via render graph (see renderGridPass callback)
        // Removed duplicate renderGridDirect call that was causing double rendering

        // Render ImGui UI
        self.renderImGuiInternal();

        // End the main renderpass
        renderpass.end(&self.context.main_renderpass, cmd_buffer.handle);

        // End the command buffer
        if (!command_buffer.end(cmd_buffer)) {
            logger.err("Failed to end command buffer.", .{});
            return false;
        }

        // Submit the command buffer
        // Use current_frame for image_available (acquire) semaphore
        // Use image_index for render_complete (present) semaphore to avoid reuse issues
        // See: https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html
        const wait_semaphore = self.context.image_available_semaphores[current_frame];
        const signal_semaphore = self.context.render_complete_semaphores[image_index];
        const wait_stage: vk.VkPipelineStageFlags = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;

        var submit_info: vk.VkSubmitInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphore,
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd_buffer.handle,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphore,
        };

        const submit_result = vk.vkQueueSubmit(
            self.context.graphics_queue,
            1,
            &submit_info,
            self.context.in_flight_fences[current_frame],
        );

        if (submit_result != vk.VK_SUCCESS) {
            logger.err("vkQueueSubmit failed with result: {}", .{submit_result});
            return false;
        }

        command_buffer.updateSubmitted(cmd_buffer);

        // Present the swapchain image
        const present_result = swapchain.present(
            &self.context,
            &self.context.swapchain,
            signal_semaphore,
            image_index,
        );

        if (present_result == vk.VK_ERROR_OUT_OF_DATE_KHR or present_result == vk.VK_SUBOPTIMAL_KHR) {
            // Swapchain needs recreation
            self.context.recreating_swapchain = true;
        } else if (present_result != vk.VK_SUCCESS) {
            logger.err("vkQueuePresentKHR failed with result: {}", .{present_result});
            return false;
        }

        // Advance to the next frame
        self.context.current_frame = (current_frame + 1) % self.context.swapchain.max_frames_in_flight;

        // Mark frame as no longer in progress
        self.context.frame_in_progress = false;

        return true;
    }

    /// Update shadow UBO with cascade matrices based on camera and directional light
    pub fn updateShadowUBO(
        self: *VulkanBackend,
        view_matrix: *const math_types.Mat4,
        _: *const math_types.Mat4,
        light_direction: *const [3]f32,
        near_plane: f32,
        far_plane: f32,
    ) void {
        const current_frame = self.context.current_frame;

        // Calculate cascade split distances using logarithmic scheme
        const near = near_plane;
        const far = far_plane;
        const lambda: f32 = 0.95; // Logarithmic split weight

        var cascade_splits: [4]f32 = undefined;
        for (0..4) |i| {
            const p = @as(f32, @floatFromInt(i + 1)) / 4.0;
            const log = near * std.math.pow(f32, far / near, p);
            const uniform = near + (far - near) * p;
            cascade_splits[i] = lambda * log + (1.0 - lambda) * uniform;
        }

        // Calculate light view matrix (looking down the light direction)
        const light_dir = math.vec3Normalize(.{
            .x = light_direction[0],
            .y = light_direction[1],
            .z = light_direction[2],
        });

        // Calculate up vector (perpendicular to light direction)
        const world_up = math.Vec3{ .x = 0, .y = 1, .z = 0 };
        const up = if (@abs(light_dir.y) > 0.99)
            math.Vec3{ .x = 1, .y = 0, .z = 0 }
        else
            world_up;

        // Get camera position from view matrix (inverse translation)
        const cam_pos = math.Vec3{
            .x = view_matrix.elements[3][0],
            .y = view_matrix.elements[3][1],
            .z = view_matrix.elements[3][2],
        };

        // Build cascade view-projection matrices
        var shadow_ubo = renderer.ShadowUBO{
            .cascade_view_proj = undefined,
            .cascade_splits = cascade_splits,
        };

        var last_split: f32 = near;
        for (0..4) |cascade_index| {
            const split_dist = cascade_splits[cascade_index];

            // Calculate frustum corners for this cascade
            // For simplicity, use a fixed orthographic projection size based on cascade distance
            const cascade_size = split_dist * 2.0;

            // Light view matrix: look from camera position along light direction
            const light_pos = math.vec3Sub(cam_pos, math.vec3Scale(light_dir, cascade_size));
            const light_view = math.mat4LookAt(light_pos, cam_pos, up);

            // Orthographic projection for cascade
            const half_size = cascade_size * 0.5;
            const light_proj = math.mat4Ortho(
                -half_size,
                half_size, // left, right
                -half_size,
                half_size, // bottom, top
                -cascade_size,
                cascade_size, // near, far
            );

            // Combine view and projection
            shadow_ubo.cascade_view_proj[cascade_index] = math.mat4Mul(light_proj, light_view);

            last_split = split_dist;
        }

        // Upload to GPU buffer
        buffer.loadData(
            &self.context,
            &self.context.shadow_uniform_buffers[current_frame],
            0,
            @sizeOf(renderer.ShadowUBO),
            @ptrCast(&shadow_ubo),
        );
    }

    /// Begin shadow rendering pass - renders all cascades
    /// Call this BEFORE beginFrame, and use drawMeshToShadowMap to render meshes
    pub fn beginShadowPass(self: *VulkanBackend) bool {
        // Shadow rendering will be done in beginFrame before the main pass
        // This is a placeholder for future enhancements
        _ = self;
        return true;
    }

    /// Draw a mesh to all shadow cascade maps
    pub fn drawMeshToShadowMaps(
        self: *VulkanBackend,
        mesh: *const @import("../../resources/mesh_asset_types.zig").MeshAsset,
        model_matrix: *const math_types.Mat4,
    ) void {
        const image_index = self.context.image_index;
        const cmd_buffer = &self.context.graphics_command_buffers[image_index];

        // Render to each cascade
        for (0..4) |cascade_index| {
            // Begin shadow renderpass for this cascade
            var clear_value: vk.VkClearValue = undefined;
            clear_value.depthStencil = .{
                .depth = 1.0,
                .stencil = 0,
            };

            var begin_info: vk.VkRenderPassBeginInfo = .{
                .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                .pNext = null,
                .renderPass = self.context.shadow_renderpass.handle,
                .framebuffer = self.context.cascade_shadow_framebuffers[cascade_index],
                .renderArea = .{
                    .offset = .{ .x = 0, .y = 0 },
                    .extent = .{ .width = 2048, .height = 2048 },
                },
                .clearValueCount = 1,
                .pClearValues = &clear_value,
            };

            vk.vkCmdBeginRenderPass(cmd_buffer.handle, &begin_info, vk.VK_SUBPASS_CONTENTS_INLINE);

            // Set viewport and scissor for shadow map resolution
            var viewport: vk.VkViewport = .{
                .x = 0.0,
                .y = 2048.0,
                .width = 2048.0,
                .height = -2048.0,
                .minDepth = 0.0,
                .maxDepth = 1.0,
            };
            vk.vkCmdSetViewport(cmd_buffer.handle, 0, 1, &viewport);

            var scissor: vk.VkRect2D = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = 2048, .height = 2048 },
            };
            vk.vkCmdSetScissor(cmd_buffer.handle, 0, 1, &scissor);

            // Set depth bias to prevent shadow acne
            const depth_bias: f32 = 0.005;
            const slope_bias: f32 = 0.01;
            vk.vkCmdSetDepthBias(cmd_buffer.handle, depth_bias, 0.0, slope_bias);

            // Bind shadow pipeline
            vk.vkCmdBindPipeline(
                cmd_buffer.handle,
                vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
                self.context.shadow_pipeline.pipeline.handle,
            );

            // Bind global descriptor set (contains ShadowUBO)
            vk.vkCmdBindDescriptorSets(
                cmd_buffer.handle,
                vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
                self.context.shadow_pipeline.pipeline.layout,
                0, // Set 0
                1,
                &self.context.global_descriptor_state.global_sets[image_index],
                0,
                null,
            );

            // Push constants: model matrix and cascade index
            var push_constants = pipeline.ShadowPushConstants{
                .model = model_matrix.*,
                .cascade_index = @intCast(cascade_index),
            };

            vk.vkCmdPushConstants(
                cmd_buffer.handle,
                self.context.shadow_pipeline.pipeline.layout,
                vk.VK_SHADER_STAGE_VERTEX_BIT,
                0,
                @sizeOf(pipeline.ShadowPushConstants),
                @ptrCast(&push_constants),
            );

            // Bind vertex and index buffers
            const offsets = [_]vk.VkDeviceSize{0};
            vk.vkCmdBindVertexBuffers(
                cmd_buffer.handle,
                0,
                1,
                &mesh.vertex_buffer.?.handle,
                &offsets,
            );

            vk.vkCmdBindIndexBuffer(
                cmd_buffer.handle,
                mesh.index_buffer.?.handle,
                0,
                vk.VK_INDEX_TYPE_UINT32,
            );

            // Draw indexed
            vk.vkCmdDrawIndexed(
                cmd_buffer.handle,
                mesh.index_count,
                1, // instance count
                0, // first index
                0, // vertex offset
                0, // first instance
            );

            // End renderpass
            vk.vkCmdEndRenderPass(cmd_buffer.handle);
        }
    }

    /// End shadow rendering pass
    pub fn endShadowPass(self: *VulkanBackend) void {
        // Shadow pass cleanup if needed
        _ = self;
    }

    /// Create a texture from raw pixel data
    pub fn createTexture(
        self: *VulkanBackend,
        tex: *resource_types.Texture,
        width: u32,
        height: u32,
        channel_count: u8,
        has_transparency: bool,
        pixels: []const u8,
    ) bool {
        return texture.create(
            &self.context,
            tex,
            width,
            height,
            channel_count,
            has_transparency,
            pixels,
        );
    }

    /// Create a cubemap texture from 6 face images
    pub fn createTextureCubemap(
        self: *VulkanBackend,
        tex: *resource_types.Texture,
        width: u32,
        height: u32,
        channel_count: u8,
        face_pixels: [6][]const u8,
    ) bool {
        return texture.createCubemap(
            &self.context,
            tex,
            width,
            height,
            channel_count,
            face_pixels,
        );
    }

    /// Destroy a texture and free all associated resources
    pub fn destroyTexture(self: *VulkanBackend, tex: *resource_types.Texture) void {
        texture.destroy(&self.context, tex);
    }

    /// Bind a texture for rendering. Pass null to use the default texture from TextureSystem.
    /// This uses per-frame texture tracking to avoid redundant descriptor set updates.
    /// IMPORTANT: Texture binding can only happen before beginFrame or after endFrame, not during frame recording.
    pub fn bindTexture(self: *VulkanBackend, tex: ?*const resource_types.Texture) void {
        // If no texture provided, try to get default from TextureSystem, fall back to backend's default
        const texture_to_bind = tex orelse texture_system.getDefaultTexture() orelse &self.context.default_texture;
        const texture_id = texture_to_bind.id;

        // Check if this texture is already bound (check any frame since we update all)
        if (self.context.bound_texture_id[0] == texture_id) {
            return;
        }

        // If we're in the middle of a frame, we CANNOT safely update descriptor sets
        // Log a warning and skip the update
        if (self.context.frame_in_progress) {
            logger.warn("Attempted to bind texture during frame recording - ignoring. Bind textures before beginFrame.", .{});
            return;
        }

        // TWO-TIER ARCHITECTURE: Textures are now bound per-material via descriptor sets
        // This function is obsolete but kept for backward compatibility
        // Just update the tracking to prevent repeated warnings
        for (&self.context.bound_texture_id) |*id| {
            id.* = texture_id;
        }
    }

    pub fn bindSpecularTexture(self: *VulkanBackend, tex: ?*const resource_types.Texture) void {
        // If no texture provided, use default texture
        const texture_to_bind = tex orelse texture_system.getDefaultTexture() orelse &self.context.default_texture;
        const texture_id = texture_to_bind.id;

        // Check if this specular texture is already bound
        if (self.context.bound_specular_texture_id[0] == texture_id) {
            return;
        }

        // If we're in the middle of a frame, we CANNOT safely update descriptor sets
        // Log a warning and skip the update
        if (self.context.frame_in_progress) {
            logger.warn("Attempted to bind specular texture during frame recording - ignoring. Bind textures before beginFrame.", .{});
            return;
        }

        // TWO-TIER ARCHITECTURE: Textures are now bound per-material via descriptor sets
        // This function is obsolete but kept for backward compatibility
        // Just update the tracking to prevent repeated warnings
        for (&self.context.bound_specular_texture_id) |*id| {
            id.* = texture_id;
        }
    }

    /// Allocate a material descriptor set and populate it with textures (legacy)
    /// Returns null on failure (pool exhaustion, invalid textures, etc.)
    pub fn allocateMaterialDescriptorSet(
        self: *VulkanBackend,
        diffuse_texture: *const resource_types.Texture,
        specular_texture: *const resource_types.Texture,
    ) ?vk.VkDescriptorSet {
        // Allocate a descriptor set from the material pool
        const descriptor_set = descriptor.allocateMaterialSet(
            &self.context,
            &self.context.material_descriptor_state,
        ) orelse {
            logger.warn("Failed to allocate material descriptor set (pool may be exhausted)", .{});
            return null;
        };

        // Update the descriptor set with the material's textures
        descriptor.updateMaterialSet(
            &self.context,
            descriptor_set,
            diffuse_texture,
            specular_texture,
        );

        return descriptor_set;
    }

    /// Allocate a material descriptor set with all 8 PBR textures including IBL
    /// Returns null on failure (pool exhaustion, invalid textures, etc.)
    pub fn allocateMaterialDescriptorSetPBR(
        self: *VulkanBackend,
        albedo_texture: *const resource_types.Texture,
        metallic_roughness_texture: *const resource_types.Texture,
        normal_texture: *const resource_types.Texture,
        ao_texture: *const resource_types.Texture,
        emissive_texture: *const resource_types.Texture,
        irradiance_texture: *const resource_types.Texture,
        prefiltered_texture: *const resource_types.Texture,
        brdf_lut_texture: *const resource_types.Texture,
    ) ?vk.VkDescriptorSet {
        // Allocate a descriptor set from the material pool
        const descriptor_set = descriptor.allocateMaterialSet(
            &self.context,
            &self.context.material_descriptor_state,
        ) orelse {
            logger.warn("Failed to allocate PBR material descriptor set (pool may be exhausted)", .{});
            return null;
        };

        // Update the descriptor set with all 8 PBR textures
        descriptor.updateMaterialSetPBR(
            &self.context,
            descriptor_set,
            albedo_texture,
            metallic_roughness_texture,
            normal_texture,
            ao_texture,
            emissive_texture,
            irradiance_texture,
            prefiltered_texture,
            brdf_lut_texture,
        );

        return descriptor_set;
    }

    /// Free a material descriptor set
    /// Note: In Vulkan, individual descriptor sets cannot be freed - they're freed when the pool is destroyed
    /// This just decrements the allocation counter for tracking purposes
    pub fn freeMaterialDescriptorSet(self: *VulkanBackend, _: vk.VkDescriptorSet) void {
        descriptor.freeMaterialSet(&self.context, &self.context.material_descriptor_state);
    }

    /// Draw geometry using its GPU buffers with a model matrix
    pub fn drawGeometry(self: *VulkanBackend, geo: *const geometry_types.Geometry, model_matrix: *const math_types.Mat4) void {
        const gpu_data = geo.internal_data orelse return;
        const geo_gpu_union: *const geometry_types.GeometryGpuData = @ptrCast(@alignCast(gpu_data));
        const geo_gpu = switch (geo_gpu_union.*) {
            .vulkan => |*v| v,
            else => return,
        };

        // Get current command buffer
        const image_index = self.context.image_index;
        const cmd = self.context.graphics_command_buffers[image_index].handle;
        const current_frame = self.context.current_frame;

        // Bind the graphics pipeline
        pipeline.bindPipeline(cmd, &self.context.material_shader.pipeline);

        // Bind all descriptor sets (Set 0: Global UBO, Set 1: Material, Set 2: Shadow)
        const descriptor_sets = [_]vk.VkDescriptorSet{
            self.context.global_descriptor_state.global_sets[current_frame], // Set 0: Global UBO
            self.context.default_material_descriptor_set, // Set 1: Material textures (default)
            self.context.shadow_descriptor_state.sets[current_frame], // Set 2: Shadow maps
        };
        vk.vkCmdBindDescriptorSets(
            cmd,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.context.material_shader.pipeline.layout,
            0,
            3, // Bind 3 descriptor sets
            &descriptor_sets,
            0,
            null,
        );

        // Push the model matrix via push constants
        const push_constant = pipeline.PushConstantObject{
            .model = model_matrix.*,
        };
        pipeline.pushConstants(cmd, self.context.material_shader.pipeline.layout, &push_constant);

        // Bind vertex buffer
        const vertex_buffers = [_]vk.VkBuffer{geo_gpu.vertex_buffer.handle};
        const offsets = [_]vk.VkDeviceSize{0};
        vk.vkCmdBindVertexBuffers(cmd, 0, 1, &vertex_buffers, &offsets);

        // Draw
        if (geo.index_count > 0 and geo_gpu.index_buffer.handle != null) {
            // Bind index buffer and draw indexed
            const index_type = geo.index_type.toVulkan();
            vk.vkCmdBindIndexBuffer(cmd, geo_gpu.index_buffer.handle, 0, index_type);
            vk.vkCmdDrawIndexed(cmd, geo.index_count, 1, 0, 0, 0);
        } else {
            // Draw non-indexed
            vk.vkCmdDraw(cmd, geo.vertex_count, 1, 0, 0);
        }
    }

    /// Bind geometry buffers for drawing (without issuing draw call)
    pub fn bindGeometry(self: *VulkanBackend, geo: *const geometry_types.Geometry) void {
        const gpu_data = geo.internal_data orelse return;
        const geo_gpu_union: *const geometry_types.GeometryGpuData = @ptrCast(@alignCast(gpu_data));
        const geo_gpu = switch (geo_gpu_union.*) {
            .vulkan => |*v| v,
            else => return,
        };

        // Get current command buffer
        const image_index = self.context.image_index;
        const cmd = self.context.graphics_command_buffers[image_index].handle;

        // Bind vertex buffer
        const vertex_buffers = [_]vk.VkBuffer{geo_gpu.vertex_buffer.handle};
        const offsets = [_]vk.VkDeviceSize{0};
        vk.vkCmdBindVertexBuffers(cmd, 0, 1, &vertex_buffers, &offsets);

        // Bind index buffer if present
        if (geo.index_count > 0 and geo_gpu.index_buffer.handle != null) {
            const index_type = geo.index_type.toVulkan();
            vk.vkCmdBindIndexBuffer(cmd, geo_gpu.index_buffer.handle, 0, index_type);
        }
    }

    /// Draw mesh asset with submesh support and per-object material
    pub fn drawMeshAsset(self: *VulkanBackend, mesh: *const @import("../../resources/mesh_asset_types.zig").MeshAsset, model_matrix: *const math_types.Mat4, material: ?*const resource_types.Material) void {
        const gpu_data = mesh.gpu_data orelse return;
        const mesh_gpu = switch (gpu_data.*) {
            .vulkan => |*v| v,
            else => return,
        };

        // Get current command buffer
        const image_index = self.context.image_index;
        const cmd = self.context.graphics_command_buffers[image_index].handle;
        const current_frame = self.context.current_frame;

        // Bind the graphics pipeline
        pipeline.bindPipeline(cmd, &self.context.material_shader.pipeline);

        // Determine which material descriptor set to use
        const material_descriptor_set = if (material) |mat|
            if (mat.descriptor_set) |ds|
                @as(vk.VkDescriptorSet, @ptrCast(ds))
            else
                self.context.default_material_descriptor_set
        else
            self.context.default_material_descriptor_set;

        // Bind all descriptor sets (Set 0: Global UBO, Set 1: Material, Set 2: Shadow)
        const descriptor_sets = [_]vk.VkDescriptorSet{
            self.context.global_descriptor_state.global_sets[current_frame], // Set 0: Global UBO
            material_descriptor_set, // Set 1: Material textures
            self.context.shadow_descriptor_state.sets[current_frame], // Set 2: Shadow maps
        };
        vk.vkCmdBindDescriptorSets(
            cmd,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.context.material_shader.pipeline.layout,
            0,
            3, // Bind 3 descriptor sets
            &descriptor_sets,
            0,
            null,
        );

        // Push the model matrix via push constants
        const push_constant = pipeline.PushConstantObject{
            .model = model_matrix.*,
        };
        pipeline.pushConstants(cmd, self.context.material_shader.pipeline.layout, &push_constant);

        // Bind vertex buffer
        const vertex_buffers = [_]vk.VkBuffer{mesh_gpu.vertex_buffer.handle};
        const offsets = [_]vk.VkDeviceSize{0};
        vk.vkCmdBindVertexBuffers(cmd, 0, 1, &vertex_buffers, &offsets);

        // Draw all submeshes
        if (mesh.index_count > 0 and mesh_gpu.index_buffer.handle != null) {
            // Bind index buffer
            const index_type = mesh.index_type.toVulkan();
            vk.vkCmdBindIndexBuffer(cmd, mesh_gpu.index_buffer.handle, 0, index_type);

            if (mesh.submesh_count > 0) {
                // Draw all submeshes
                for (mesh.submeshes[0..mesh.submesh_count]) |*submesh| {
                    vk.vkCmdDrawIndexed(cmd, submesh.index_count, 1, submesh.index_offset, 0, 0);
                }
            } else {
                // Draw entire mesh
                vk.vkCmdDrawIndexed(cmd, mesh.index_count, 1, 0, 0, 0);
            }
        } else {
            // Draw non-indexed
            if (mesh.submesh_count > 0) {
                // Draw all submeshes
                for (mesh.submeshes[0..mesh.submesh_count]) |*submesh| {
                    vk.vkCmdDraw(cmd, submesh.vertex_count, 1, submesh.vertex_offset, 0);
                }
            } else {
                vk.vkCmdDraw(cmd, mesh.vertex_count, 1, 0, 0);
            }
        }
    }

    // --- Private helper functions ---

    fn createDebugMessenger(self: *VulkanBackend) bool {
        logger.debug("Creating Vulkan debug messenger...", .{});

        const log_severity: u32 = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT;

        const message_type: u32 = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;

        var debug_create_info: vk.VkDebugUtilsMessengerCreateInfoEXT = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .pNext = null,
            .flags = 0,
            .messageSeverity = log_severity,
            .messageType = message_type,
            .pfnUserCallback = vk_context.debugCallback,
            .pUserData = null,
        };

        // Get the function pointer for vkCreateDebugUtilsMessengerEXT
        const func_ptr = vk.vkGetInstanceProcAddr(
            self.context.instance,
            "vkCreateDebugUtilsMessengerEXT",
        );

        if (func_ptr == null) {
            logger.err("Failed to get vkCreateDebugUtilsMessengerEXT function pointer!", .{});
            return false;
        }

        const create_func: vk_context.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(func_ptr);

        const result = create_func(
            self.context.instance,
            &debug_create_info,
            null,
            &self.context.debug_messenger,
        );

        if (result != vk.VK_SUCCESS) {
            logger.err("vkCreateDebugUtilsMessengerEXT failed with result: {}", .{result});
            return false;
        }

        logger.debug("Vulkan debug messenger created.", .{});
        return true;
    }

    fn destroyDebugMessenger(self: *VulkanBackend) void {
        if (self.context.debug_messenger == null) return;

        logger.debug("Destroying Vulkan debug messenger...", .{});

        const func_ptr = vk.vkGetInstanceProcAddr(
            self.context.instance,
            "vkDestroyDebugUtilsMessengerEXT",
        );

        if (func_ptr) |ptr| {
            const destroy_func: vk_context.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(ptr);
            destroy_func(self.context.instance, self.context.debug_messenger, null);
            self.context.debug_messenger = null;
        }
    }

    fn createSurface(self: *VulkanBackend) bool {
        logger.debug("Creating Vulkan surface...", .{});

        // Get window from engine context
        const window_ptr = engine_context.get().platform_window orelse {
            logger.err("No platform window available for surface creation.", .{});
            return false;
        };
        const window: *glfw.GLFWwindow = @ptrCast(@alignCast(window_ptr));

        // Use GLFW to create the surface (platform-agnostic)
        // Note: glfwCreateWindowSurface returns VkResult but uses GLFW's VkInstance type
        // We need to cast our instance to the GLFW expected type
        const instance: glfw.VkInstance = @ptrCast(self.context.instance);
        var surface: glfw.VkSurfaceKHR = null;

        const result = glfw.glfwCreateWindowSurface(
            instance,
            window,
            null, // allocator callbacks
            &surface,
        );

        if (result != glfw.VK_SUCCESS) {
            logger.err("Failed to create Vulkan surface. Error: {}", .{result});
            return false;
        }

        // Cast back to our Vulkan type
        self.context.surface = @ptrCast(surface);

        logger.info("Vulkan surface created.", .{});
        return true;
    }

    fn destroySurface(self: *VulkanBackend) void {
        if (self.context.surface == null) return;

        logger.debug("Destroying Vulkan surface...", .{});

        if (self.context.instance) |instance| {
            vk.vkDestroySurfaceKHR(instance, self.context.surface, self.context.allocator);
            self.context.surface = null;
        }
    }

    fn createCommandBuffers(self: *VulkanBackend) bool {
        logger.debug("Allocating {} command buffers...", .{self.context.swapchain.image_count});

        for (0..self.context.swapchain.image_count) |i| {
            if (!command_buffer.allocate(
                &self.context,
                self.context.graphics_command_pool,
                true,
                &self.context.graphics_command_buffers[i],
            )) {
                logger.err("Failed to allocate command buffer {}", .{i});
                return false;
            }
        }

        logger.info("Command buffers allocated.", .{});
        return true;
    }

    fn destroyCommandBuffers(self: *VulkanBackend) void {
        logger.debug("Freeing command buffers...", .{});

        for (&self.context.graphics_command_buffers) |*cmd_buf| {
            command_buffer.free(
                &self.context,
                self.context.graphics_command_pool,
                cmd_buf,
            );
        }
    }

    fn createSyncObjects(self: *VulkanBackend) bool {
        logger.debug("Creating synchronization objects...", .{});

        const max_frames = self.context.swapchain.max_frames_in_flight;
        const image_count = self.context.swapchain.image_count;

        // Create per-frame synchronization objects (for CPU-GPU sync)
        for (0..max_frames) |i| {
            // Create image available semaphore (one per frame in flight)
            if (!command_buffer.createSemaphore(&self.context, &self.context.image_available_semaphores[i])) {
                logger.err("Failed to create image available semaphore {}", .{i});
                return false;
            }

            // Create in-flight fence (signaled so first frame doesn't wait forever)
            if (!command_buffer.createFence(&self.context, &self.context.in_flight_fences[i], true)) {
                logger.err("Failed to create in-flight fence {}", .{i});
                return false;
            }
        }

        // Create per-image synchronization objects (for presentation)
        // render_complete semaphores are indexed by image_index, so we need one per swapchain image
        for (0..image_count) |i| {
            if (!command_buffer.createSemaphore(&self.context, &self.context.render_complete_semaphores[i])) {
                logger.err("Failed to create render complete semaphore {}", .{i});
                return false;
            }
        }

        // Initialize images_in_flight to null (no image is initially in use)
        for (&self.context.images_in_flight) |*fence| {
            fence.* = null;
        }

        logger.info("Synchronization objects created.", .{});
        return true;
    }

    fn destroySyncObjects(self: *VulkanBackend) void {
        logger.debug("Destroying synchronization objects...", .{});

        for (&self.context.image_available_semaphores) |*sem| {
            command_buffer.destroySemaphore(&self.context, sem);
        }

        for (&self.context.render_complete_semaphores) |*sem| {
            command_buffer.destroySemaphore(&self.context, sem);
        }

        for (&self.context.in_flight_fences) |*fence| {
            command_buffer.destroyFence(&self.context, fence);
        }

        // images_in_flight are just references, not owned
        for (&self.context.images_in_flight) |*fence| {
            fence.* = null;
        }
    }

    fn createGlobalUniformBuffers(self: *VulkanBackend) bool {
        logger.debug("Creating global uniform buffers...", .{});

        // Use shared GlobalUBO from renderer module
        const ubo_size = @sizeOf(renderer.GlobalUBO);

        for (0..self.context.swapchain.max_frames_in_flight) |i| {
            if (!buffer.create(
                &self.context,
                &self.context.global_uniform_buffers[i],
                ubo_size,
                buffer.BufferUsage.uniform,
                buffer.MemoryFlags.host_visible,
            )) {
                logger.err("Failed to create global uniform buffer {}", .{i});
                return false;
            }
        }

        logger.info("Global uniform buffers created.", .{});
        return true;
    }

    fn destroyGlobalUniformBuffers(self: *VulkanBackend) void {
        logger.debug("Destroying global uniform buffers...", .{});

        for (&self.context.global_uniform_buffers) |*buf| {
            buffer.destroy(&self.context, buf);
        }
    }

    fn updateDescriptorSets(self: *VulkanBackend) void {
        for (0..self.context.swapchain.max_frames_in_flight) |i| {
            var buffer_info: vk.VkDescriptorBufferInfo = .{
                .buffer = self.context.global_uniform_buffers[i].handle,
                .offset = 0,
                .range = @sizeOf(renderer.GlobalUBO),
            };

            descriptor.updateGlobalSet(
                &self.context,
                &self.context.global_descriptor_state,
                @intCast(i),
                &buffer_info,
            );
        }
    }

    fn createDefaultTexture(self: *VulkanBackend) bool {
        logger.debug("Creating default texture...", .{});

        // Create a checkerboard pattern texture (8x8 with 2x2 squares)
        const texture_size = 8;
        const square_size = 2;
        const light_gray = [4]u8{ 200, 200, 200, 255 };
        const dark_gray = [4]u8{ 100, 100, 100, 255 };

        var pixels: [texture_size * texture_size * 4]u8 = undefined;

        for (0..texture_size) |y| {
            for (0..texture_size) |x| {
                const idx = (y * texture_size + x) * 4;
                // Determine which square we're in
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

        if (!texture.createWithFilter(
            &self.context,
            &self.context.default_texture,
            texture_size,
            texture_size,
            4, // RGBA
            false, // no transparency
            &pixels,
            .nearest, // Use nearest filtering for sharp checkerboard edges
        )) {
            logger.err("Failed to create default texture", .{});
            return false;
        }

        // Allocate material descriptor set for default texture (uses same texture for diffuse and specular)
        const default_descriptor_set = descriptor.allocateMaterialSet(
            &self.context,
            &self.context.material_descriptor_state,
        ) orelse {
            logger.err("Failed to allocate descriptor set for default texture", .{});
            return false;
        };

        // Update material descriptor set with both diffuse and specular pointing to the same default texture
        descriptor.updateMaterialSet(
            &self.context,
            default_descriptor_set,
            &self.context.default_texture,
            &self.context.default_texture,
        );

        // Store descriptor set in context
        self.context.default_material_descriptor_set = default_descriptor_set;

        logger.info("Default texture created ({}x{} checkerboard) with descriptor set.", .{ texture_size, texture_size });
        return true;
    }

    fn loadShaders(self: *VulkanBackend) bool {
        logger.debug("Loading shaders...", .{});

        const allocator = std.heap.page_allocator;

        // Load vertex shader
        if (!shader.load(
            &self.context,
            allocator,
            "build/shaders/Builtin.MaterialShader.vert.spv",
            .vertex,
            &self.context.material_shader.vertex_shader,
        )) {
            logger.err("Failed to load vertex shader.", .{});
            return false;
        }

        // Load fragment shader
        if (!shader.load(
            &self.context,
            allocator,
            "build/shaders/Builtin.MaterialShader.frag.spv",
            .fragment,
            &self.context.material_shader.fragment_shader,
        )) {
            logger.err("Failed to load fragment shader.", .{});
            return false;
        }

        logger.info("Shaders loaded.", .{});
        return true;
    }

    /// Update the global UBO with data from the renderer system.
    /// This is called by the renderer system at the start of each frame.
    pub fn updateUBO(self: *VulkanBackend, ubo: *const renderer.GlobalUBO) void {
        const current_frame = self.context.current_frame;

        // Upload UBO data to the current frame's buffer
        _ = buffer.loadData(
            &self.context,
            &self.context.global_uniform_buffers[current_frame],
            0,
            @sizeOf(renderer.GlobalUBO),
            ubo,
        );
    }

    /// Get the current command buffer handle for render graph passes
    /// Returns null if not currently recording a frame
    pub fn getCurrentCommandBuffer(self: *VulkanBackend) ?vk.VkCommandBuffer {
        if (!self.context.frame_in_progress) return null;
        return self.context.graphics_command_buffers[self.context.image_index].handle;
    }

    /// Get the Vulkan context (for advanced render graph integration)
    pub fn getContext(self: *VulkanBackend) *vk_context.VulkanContext {
        return &self.context;
    }

    /// Get the current frame index
    pub fn getCurrentFrame(self: *VulkanBackend) u32 {
        return self.context.current_frame;
    }

    /// Get the current image index
    pub fn getImageIndex(self: *VulkanBackend) u32 {
        return self.context.image_index;
    }

    // =========================================================================
    // ImGui Integration (conditional on build_options.enable_imgui)
    // =========================================================================

    /// Initialize ImGui with GLFW and Vulkan backends
    pub fn initImGui(self: *VulkanBackend) bool {
        if (!build_options.enable_imgui) {
            return true; // No-op success when ImGui is disabled
        }

        const window_ptr = engine_context.get().platform_window orelse {
            logger.err("ImGui: No platform window available", .{});
            return false;
        };

        // Create descriptor pool for ImGui
        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 100,
            },
        };

        const pool_info: vk.VkDescriptorPoolCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
            .maxSets = 100,
            .poolSizeCount = pool_sizes.len,
            .pPoolSizes = &pool_sizes,
        };

        const result = vk.vkCreateDescriptorPool(
            self.context.device,
            &pool_info,
            self.context.allocator,
            &self.imgui_descriptor_pool,
        );
        if (result != vk.VK_SUCCESS) {
            logger.err("ImGui: Failed to create descriptor pool", .{});
            return false;
        }

        // Initialize GLFW backend for input handling
        // Note: install_callbacks=false because we forward events from platform.zig callbacks
        if (!imgui_glfw.cImGui_ImplGlfw_InitForVulkan(@ptrCast(window_ptr), false)) {
            logger.err("ImGui: Failed to initialize GLFW backend", .{});
            vk.vkDestroyDescriptorPool(self.context.device, self.imgui_descriptor_pool, self.context.allocator);
            self.imgui_descriptor_pool = null;
            return false;
        }

        // Setup Vulkan init info
        // Note: We need to cast Vulkan handles because imgui_vulkan has its own opaque types
        var init_info: imgui_vulkan.ImGui_ImplVulkan_InitInfo = std.mem.zeroes(imgui_vulkan.ImGui_ImplVulkan_InitInfo);
        init_info.ApiVersion = vk.VK_API_VERSION_1_2;
        init_info.Instance = @ptrCast(self.context.instance);
        init_info.PhysicalDevice = @ptrCast(self.context.physical_device);
        init_info.Device = @ptrCast(self.context.device);
        init_info.QueueFamily = self.context.queue_family_indices.graphics_family orelse 0;
        init_info.Queue = @ptrCast(self.context.graphics_queue);
        init_info.DescriptorPool = @ptrCast(self.imgui_descriptor_pool);
        init_info.MinImageCount = 2;
        init_info.ImageCount = self.context.swapchain.image_count;
        init_info.PipelineCache = null;
        init_info.Allocator = @ptrCast(self.context.allocator);
        init_info.CheckVkResultFn = null;
        init_info.UseDynamicRendering = false;

        // Set up pipeline info with render pass
        init_info.PipelineInfoMain.RenderPass = @ptrCast(self.context.main_renderpass.handle);
        init_info.PipelineInfoMain.Subpass = 0;
        init_info.PipelineInfoMain.MSAASamples = vk.VK_SAMPLE_COUNT_1_BIT;

        // Initialize Vulkan backend
        if (!imgui_vulkan.cImGui_ImplVulkan_Init(&init_info)) {
            logger.err("ImGui: Failed to initialize Vulkan backend", .{});
            imgui_glfw.cImGui_ImplGlfw_Shutdown();
            vk.vkDestroyDescriptorPool(self.context.device, self.imgui_descriptor_pool, self.context.allocator);
            self.imgui_descriptor_pool = null;
            return false;
        }

        self.imgui_initialized = true;
        logger.info("ImGui Vulkan backend initialized", .{});
        return true;
    }

    /// Shutdown ImGui backends
    pub fn shutdownImGui(self: *VulkanBackend) void {
        if (!build_options.enable_imgui) return;
        if (!self.imgui_initialized) return;

        // Wait for device to be idle before cleanup
        _ = vk.vkDeviceWaitIdle(self.context.device);

        imgui_vulkan.cImGui_ImplVulkan_Shutdown();
        imgui_glfw.cImGui_ImplGlfw_Shutdown();

        if (self.imgui_descriptor_pool != null) {
            vk.vkDestroyDescriptorPool(self.context.device, self.imgui_descriptor_pool, self.context.allocator);
            self.imgui_descriptor_pool = null;
        }

        self.imgui_initialized = false;
        logger.info("ImGui Vulkan backend shutdown", .{});
    }

    /// Begin ImGui frame
    pub fn beginImGuiFrame(self: *VulkanBackend) void {
        if (!build_options.enable_imgui) return;
        if (!self.imgui_initialized) {
            logger.warn("ImGui beginFrame called but not initialized", .{});
            return;
        }

        // Order matters! GLFW first (input), then Vulkan (rendering)
        imgui_glfw.cImGui_ImplGlfw_NewFrame();
        imgui_vulkan.cImGui_ImplVulkan_NewFrame();
    }

    /// Store ImGui draw data for deferred rendering during tonemap pass
    /// This is called during the HDR pass, but actual rendering happens in endFrame during tonemap pass
    pub fn renderImGui(self: *VulkanBackend, draw_data: ?*anyopaque) void {
        if (!build_options.enable_imgui) return;
        if (!self.imgui_initialized) return;
        if (draw_data == null) return;

        // Store the draw data pointer for rendering during the tonemap pass
        // The draw data remains valid until the next ImGui frame begins
        self.pending_imgui_draw_data = draw_data;
    }

    /// Internal function to actually render ImGui during the tonemap pass
    fn renderImGuiInternal(self: *VulkanBackend) void {
        if (!build_options.enable_imgui) return;
        if (!self.imgui_initialized) return;
        if (self.pending_imgui_draw_data == null) return;

        // Get current command buffer
        const cmd_buf = self.context.graphics_command_buffers[self.context.image_index].handle;
        if (cmd_buf == null) return;

        // Cast draw_data with proper alignment and command buffer to imgui's type
        const imgui_draw_data: *imgui_vulkan.ImDrawData = @ptrCast(@alignCast(self.pending_imgui_draw_data));
        imgui_vulkan.cImGui_ImplVulkan_RenderDrawData(imgui_draw_data, @ptrCast(cmd_buf));

        // Clear the pending draw data
        self.pending_imgui_draw_data = null;
    }

    // =========================================================================
    // Grid Rendering Functions (Editor Only)
    // =========================================================================

    /// Initialize grid rendering resources
    fn initializeGrid(self: *VulkanBackend) bool {
        logger.debug("Initializing grid rendering...", .{});

        // Load grid shaders
        if (!self.loadGridShaders()) {
            logger.err("Failed to load grid shaders.", .{});
            return false;
        }

        // Create grid descriptor layout and pool
        if (!descriptor.createGridLayout(&self.context, &self.context.grid_descriptor_state)) {
            logger.err("Failed to create grid descriptor layout.", .{});
            return false;
        }

        const frame_count = self.context.swapchain.max_frames_in_flight;
        if (!descriptor.createGridPool(&self.context, &self.context.grid_descriptor_state, frame_count)) {
            descriptor.destroyGridLayout(&self.context, &self.context.grid_descriptor_state);
            return false;
        }

        if (!descriptor.allocateGridSets(&self.context, &self.context.grid_descriptor_state, frame_count)) {
            descriptor.destroyGridPool(&self.context, &self.context.grid_descriptor_state);
            descriptor.destroyGridLayout(&self.context, &self.context.grid_descriptor_state);
            return false;
        }

        // Create grid pipeline
        if (!pipeline.createGridPipeline(
            &self.context,
            &self.context.grid_shader,
            self.context.grid_descriptor_state.layout,
            self.context.main_renderpass.handle,
        )) {
            descriptor.destroyGridPool(&self.context, &self.context.grid_descriptor_state);
            descriptor.destroyGridLayout(&self.context, &self.context.grid_descriptor_state);
            return false;
        }

        // Create grid uniform buffers
        if (!self.createGridUniformBuffers()) {
            pipeline.destroyGridShader(&self.context, &self.context.grid_shader);
            descriptor.destroyGridPool(&self.context, &self.context.grid_descriptor_state);
            descriptor.destroyGridLayout(&self.context, &self.context.grid_descriptor_state);
            return false;
        }

        // Create grid geometry
        if (!self.createGridGeometry()) {
            self.cleanupGridBuffers();
            pipeline.destroyGridShader(&self.context, &self.context.grid_shader);
            descriptor.destroyGridPool(&self.context, &self.context.grid_descriptor_state);
            descriptor.destroyGridLayout(&self.context, &self.context.grid_descriptor_state);
            return false;
        }

        logger.info("Grid rendering initialized.", .{});
        return true;
    }

    /// Cleanup grid resources
    fn cleanupGrid(self: *VulkanBackend) void {
        // Destroy geometry buffers
        buffer.destroy(&self.context, &self.context.grid_geometry_vertex_buffer);
        buffer.destroy(&self.context, &self.context.grid_geometry_index_buffer);

        // Destroy uniform buffers
        self.cleanupGridBuffers();

        // Destroy descriptor state
        descriptor.destroyGridPool(&self.context, &self.context.grid_descriptor_state);
        descriptor.destroyGridLayout(&self.context, &self.context.grid_descriptor_state);

        // Destroy pipeline and shaders
        pipeline.destroyGridShader(&self.context, &self.context.grid_shader);
    }

    /// Load grid shaders
    fn loadGridShaders(self: *VulkanBackend) bool {
        logger.debug("Loading grid shaders...", .{});

        const allocator = std.heap.page_allocator;

        // Load vertex shader
        if (!shader.load(
            &self.context,
            allocator,
            "build/shaders/Builtin.GridShader.vert.spv",
            .vertex,
            &self.context.grid_shader.vertex_shader,
        )) {
            logger.err("Failed to load grid vertex shader.", .{});
            return false;
        }

        // Load fragment shader
        if (!shader.load(
            &self.context,
            allocator,
            "build/shaders/Builtin.GridShader.frag.spv",
            .fragment,
            &self.context.grid_shader.fragment_shader,
        )) {
            logger.err("Failed to load grid fragment shader.", .{});
            shader.destroy(&self.context, &self.context.grid_shader.vertex_shader);
            return false;
        }

        logger.info("Grid shaders loaded.", .{});
        return true;
    }

    /// Create grid uniform buffers
    fn createGridUniformBuffers(self: *VulkanBackend) bool {
        const frame_count = self.context.swapchain.max_frames_in_flight;

        // Create camera uniform buffers (one per frame)
        for (0..frame_count) |i| {
            if (!buffer.create(
                &self.context,
                &self.context.grid_camera_buffers[i],
                @sizeOf(renderer.GridCameraUBO),
                buffer.BufferUsage.uniform,
                buffer.MemoryFlags.host_visible,
            )) {
                logger.err("Failed to create grid camera uniform buffer {}", .{i});
                return false;
            }
        }

        // Create grid UBO buffers (one per frame)
        for (0..frame_count) |i| {
            if (!buffer.create(
                &self.context,
                &self.context.grid_ubo_buffers[i],
                @sizeOf(renderer.GridUBO),
                buffer.BufferUsage.uniform,
                buffer.MemoryFlags.host_visible,
            )) {
                logger.err("Failed to create grid UBO buffer {}", .{i});
                return false;
            }

            // Upload default grid configuration
            var grid_ubo = renderer.GridUBO.initDefault();
            _ = buffer.loadData(
                &self.context,
                &self.context.grid_ubo_buffers[i],
                0,
                @sizeOf(renderer.GridUBO),
                &grid_ubo,
            );
        }

        // Update descriptor sets
        for (0..frame_count) |i| {
            descriptor.updateGridSet(
                &self.context,
                &self.context.grid_descriptor_state,
                @intCast(i),
                self.context.grid_camera_buffers[i].handle,
                self.context.grid_ubo_buffers[i].handle,
            );
        }

        logger.debug("Grid uniform buffers created.", .{});
        return true;
    }

    /// Cleanup grid buffers
    fn cleanupGridBuffers(self: *VulkanBackend) void {
        const frame_count = self.context.swapchain.max_frames_in_flight;
        for (0..frame_count) |i| {
            buffer.destroy(&self.context, &self.context.grid_camera_buffers[i]);
            buffer.destroy(&self.context, &self.context.grid_ubo_buffers[i]);
        }
    }

    // =========================================================================
    // Shadow System
    // =========================================================================

    /// Initialize shadow mapping system
    fn initializeShadowSystem(self: *VulkanBackend) bool {
        const shadow_res: u32 = 2048; // CASCADE_RESOLUTION from shadow_system.zig

        // Create shadow renderpass
        if (!renderpass.createShadowRenderpass(
            &self.context,
            &self.context.shadow_renderpass,
            shadow_res,
            shadow_res,
        )) {
            logger.err("Failed to create shadow renderpass.", .{});
            return false;
        }

        // Create shadow sampler (depth comparison sampler)
        if (!self.createShadowSampler()) {
            logger.err("Failed to create shadow sampler.", .{});
            return false;
        }

        // Create cascade shadow map images and framebuffers
        for (0..4) |i| {
            if (!self.createCascadeShadowMap(i, shadow_res)) {
                logger.err("Failed to create cascade shadow map {}.", .{i});
                return false;
            }
        }

        // Create shadow UBO buffers (one per frame in flight)
        const frame_count = self.context.swapchain.max_frames_in_flight;
        for (0..frame_count) |i| {
            if (!buffer.create(
                &self.context,
                &self.context.shadow_uniform_buffers[i],
                @sizeOf(renderer.ShadowUBO),
                vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            )) {
                logger.err("Failed to create shadow uniform buffer {}.", .{i});
                return false;
            }
        }

        // Create default cubemap for point shadow placeholders
        if (!self.createDefaultCubemap()) {
            logger.err("Failed to create default cubemap.", .{});
            return false;
        }

        // Update shadow descriptor sets with shadow UBO and default cubemaps
        self.updateShadowDescriptorSets();

        logger.info("Shadow system initialized successfully.", .{});
        return true;
    }

    /// Cleanup shadow system resources
    fn cleanupShadowSystem(self: *VulkanBackend) void {
        // Destroy shadow UBO buffers
        const frame_count = self.context.swapchain.max_frames_in_flight;
        for (0..frame_count) |i| {
            buffer.destroy(&self.context, &self.context.shadow_uniform_buffers[i]);
        }

        // Destroy cascade shadow maps
        for (0..4) |i| {
            if (self.context.cascade_shadow_framebuffers[i] != null) {
                vk.vkDestroyFramebuffer(
                    self.context.device,
                    self.context.cascade_shadow_framebuffers[i],
                    self.context.allocator,
                );
            }
            // Note: ImageView is destroyed automatically by image.destroy()
            // Don't destroy it explicitly to avoid double-free
            image.destroy(&self.context, &self.context.cascade_shadow_images[i]);
        }

        // Destroy shadow sampler
        if (self.context.shadow_sampler != null) {
            vk.vkDestroySampler(
                self.context.device,
                self.context.shadow_sampler,
                self.context.allocator,
            );
        }

        // Destroy default cubemap (image.destroy will handle the view)
        image.destroy(&self.context, &self.context.default_cubemap_image);
        self.context.default_cubemap_view = null;

        // Destroy shadow renderpass
        renderpass.destroy(&self.context, &self.context.shadow_renderpass);
    }

    /// Create shadow sampler with depth comparison
    fn createShadowSampler(self: *VulkanBackend) bool {
        // MoltenVK doesn't support mutable comparison samplers, so we disable comparison
        // and do manual depth comparison in the shader
        var sampler_info: vk.VkSamplerCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = vk.VK_FILTER_LINEAR,
            .minFilter = vk.VK_FILTER_LINEAR,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_LINEAR,
            .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
            .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
            .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
            .mipLodBias = 0.0,
            .anisotropyEnable = vk.VK_FALSE,
            .maxAnisotropy = 1.0,
            .compareEnable = vk.VK_FALSE, // Disabled for MoltenVK portability
            .compareOp = vk.VK_COMPARE_OP_LESS_OR_EQUAL,
            .minLod = 0.0,
            .maxLod = 1.0,
            .borderColor = vk.VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE, // Depth 1.0 (no shadow)
            .unnormalizedCoordinates = vk.VK_FALSE,
        };

        const result = vk.vkCreateSampler(
            self.context.device,
            &sampler_info,
            self.context.allocator,
            &self.context.shadow_sampler,
        );

        if (result != vk.VK_SUCCESS) {
            logger.err("vkCreateSampler (shadow) failed: {}", .{result});
            return false;
        }

        return true;
    }

    /// Create a default cubemap for point shadow placeholders (1x1 depth cubemap)
    fn createDefaultCubemap(self: *VulkanBackend) bool {
        const size: u32 = 1;

        // Create cubemap image (6 layers)
        var image_info: vk.VkImageCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_D32_SFLOAT,
            .extent = .{
                .width = size,
                .height = size,
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 6, // Cubemap has 6 faces
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        var result = vk.vkCreateImage(
            self.context.device,
            &image_info,
            self.context.allocator,
            &self.context.default_cubemap_image.handle,
        );

        if (result != vk.VK_SUCCESS) {
            logger.err("vkCreateImage (default cubemap) failed: {}", .{result});
            return false;
        }

        // Allocate memory
        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(
            self.context.device,
            self.context.default_cubemap_image.handle,
            &mem_requirements,
        );

        const memory_type_index = image.findMemoryType(
            &self.context,
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );

        if (memory_type_index == null) {
            logger.err("Failed to find suitable memory type for default cubemap", .{});
            vk.vkDestroyImage(self.context.device, self.context.default_cubemap_image.handle, self.context.allocator);
            return false;
        }

        var alloc_info: vk.VkMemoryAllocateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = memory_type_index.?,
        };

        result = vk.vkAllocateMemory(
            self.context.device,
            &alloc_info,
            self.context.allocator,
            &self.context.default_cubemap_image.memory,
        );

        if (result != vk.VK_SUCCESS) {
            logger.err("vkAllocateMemory (default cubemap) failed: {}", .{result});
            return false;
        }

        result = vk.vkBindImageMemory(
            self.context.device,
            self.context.default_cubemap_image.handle,
            self.context.default_cubemap_image.memory,
            0,
        );

        if (result != vk.VK_SUCCESS) {
            logger.err("vkBindImageMemory (default cubemap) failed: {}", .{result});
            return false;
        }

        // Transition all 6 cubemap layers to shader read layout
        var temp_cmd_buffer: command_buffer.VulkanCommandBuffer = .{};
        if (!command_buffer.allocateAndBeginSingleUse(
            &self.context,
            self.context.graphics_command_pool,
            &temp_cmd_buffer,
        )) {
            logger.err("Failed to allocate transition command buffer for default cubemap.", .{});
            return false;
        }

        // Transition all 6 layers of the cubemap
        var barrier: vk.VkImageMemoryBarrier = .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.context.default_cubemap_image.handle,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_DEPTH_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 6, // All 6 cubemap faces
            },
        };

        vk.vkCmdPipelineBarrier(
            temp_cmd_buffer.handle,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier,
        );

        if (!command_buffer.endSingleUse(
            &self.context,
            self.context.graphics_command_pool,
            &temp_cmd_buffer,
            self.context.graphics_queue,
        )) {
            logger.err("Failed to submit transition command buffer for default cubemap.", .{});
            return false;
        }

        // Create cubemap view
        var view_info: vk.VkImageViewCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.context.default_cubemap_image.handle,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_CUBE,
            .format = vk.VK_FORMAT_D32_SFLOAT,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_DEPTH_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 6, // All 6 faces
            },
        };

        result = vk.vkCreateImageView(
            self.context.device,
            &view_info,
            self.context.allocator,
            &self.context.default_cubemap_view,
        );

        if (result != vk.VK_SUCCESS) {
            logger.err("vkCreateImageView (default cubemap) failed: {}", .{result});
            return false;
        }

        self.context.default_cubemap_image.view = self.context.default_cubemap_view;
        logger.debug("Default cubemap created ({}x{} depth cubemap).", .{ size, size });
        return true;
    }

    /// Create a single cascade shadow map (image + view + framebuffer)
    fn createCascadeShadowMap(self: *VulkanBackend, cascade_index: usize, resolution: u32) bool {
        // Create depth image
        if (!image.create(
            &self.context,
            &self.context.cascade_shadow_images[cascade_index],
            resolution,
            resolution,
            vk.VK_FORMAT_D32_SFLOAT,
            vk.VK_IMAGE_TILING_OPTIMAL,
            vk.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            vk.VK_IMAGE_ASPECT_DEPTH_BIT,
        )) {
            logger.err("Failed to create cascade {} shadow image.", .{cascade_index});
            return false;
        }

        // Transition image layout to SHADER_READ_ONLY_OPTIMAL
        // This is needed because we're creating the image in UNDEFINED layout
        // but the descriptor set expects it to be in SHADER_READ_ONLY_OPTIMAL
        var temp_cmd_buffer: command_buffer.VulkanCommandBuffer = .{};
        if (!command_buffer.allocateAndBeginSingleUse(
            &self.context,
            self.context.graphics_command_pool,
            &temp_cmd_buffer,
        )) {
            logger.err("Failed to allocate transition command buffer for cascade {}.", .{cascade_index});
            return false;
        }

        image.transitionLayout(
            &self.context,
            temp_cmd_buffer.handle,
            self.context.cascade_shadow_images[cascade_index].handle,
            vk.VK_FORMAT_D32_SFLOAT,
            vk.VK_IMAGE_LAYOUT_UNDEFINED,
            vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            1,
        );

        if (!command_buffer.endSingleUse(
            &self.context,
            self.context.graphics_command_pool,
            &temp_cmd_buffer,
            self.context.graphics_queue,
        )) {
            logger.err("Failed to submit transition command buffer for cascade {}.", .{cascade_index});
            return false;
        }

        // Image view is created by image.create, so we just store a reference
        self.context.cascade_shadow_views[cascade_index] = self.context.cascade_shadow_images[cascade_index].view;

        // Create framebuffer
        var attachments = [_]vk.VkImageView{self.context.cascade_shadow_views[cascade_index]};

        var framebuffer_info: vk.VkFramebufferCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = self.context.shadow_renderpass.handle,
            .attachmentCount = attachments.len,
            .pAttachments = &attachments,
            .width = resolution,
            .height = resolution,
            .layers = 1,
        };

        const result = vk.vkCreateFramebuffer(
            self.context.device,
            &framebuffer_info,
            self.context.allocator,
            &self.context.cascade_shadow_framebuffers[cascade_index],
        );

        if (result != vk.VK_SUCCESS) {
            logger.err("vkCreateFramebuffer (cascade {}) failed: {}", .{ cascade_index, result });
            return false;
        }

        return true;
    }

    /// Update shadow descriptor sets with shadow map textures
    fn updateShadowDescriptorSets(self: *VulkanBackend) void {
        const frame_count = self.context.swapchain.max_frames_in_flight;

        // Prepare cascade shadow map image infos
        var cascade_image_infos: [4]vk.VkDescriptorImageInfo = undefined;
        for (0..4) |i| {
            cascade_image_infos[i] = .{
                .sampler = self.context.shadow_sampler,
                .imageView = self.context.cascade_shadow_views[i],
                .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
        }

        // Prepare point shadow cubemap image infos (using default cubemap as placeholder)
        var point_image_infos: [4]vk.VkDescriptorImageInfo = undefined;
        for (0..4) |i| {
            point_image_infos[i] = .{
                .sampler = self.context.shadow_sampler,
                .imageView = self.context.default_cubemap_view,
                .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
        }

        // Update descriptor sets for each frame
        for (0..frame_count) |i| {
            descriptor.updateShadowDescriptorSet(
                &self.context,
                &self.context.shadow_descriptor_state,
                @intCast(i),
                &cascade_image_infos,
            );

            // Update point shadow cubemaps (default placeholders for now)
            descriptor.updatePointShadowDescriptorSet(
                &self.context,
                &self.context.shadow_descriptor_state,
                @intCast(i),
                &point_image_infos,
            );

            // Update shadow UBO in global descriptor set (Set 0, Binding 1)
            var shadow_buffer_info: vk.VkDescriptorBufferInfo = .{
                .buffer = self.context.shadow_uniform_buffers[i].handle,
                .offset = 0,
                .range = @sizeOf(renderer.ShadowUBO),
            };

            descriptor.updateShadowSet(
                &self.context,
                &self.context.global_descriptor_state,
                @intCast(i),
                &shadow_buffer_info,
            );
        }
    }

    /// Create grid geometry (1000x1000 quad)
    fn createGridGeometry(self: *VulkanBackend) bool {
        // Temporarily use smaller grid for debugging visibility
        const grid_size: f32 = 2000.0; // Increased from 1000 to ensure it's visible
        const half_size = grid_size / 2.0;

        // Vertex positions (simple quad in XZ plane)
        const vertices = [_][3]f32{
            .{ -half_size, 0.0, -half_size }, // Bottom-left
            .{ half_size, 0.0, -half_size }, // Bottom-right
            .{ half_size, 0.0, half_size }, // Top-right
            .{ -half_size, 0.0, half_size }, // Top-left
        };

        // Indices for two triangles
        const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

        self.context.grid_geometry_vertex_count = vertices.len;
        self.context.grid_geometry_index_count = indices.len;

        // Create vertex buffer (use host-visible memory for simplicity - grid is small and static)
        const vertex_buffer_size = @sizeOf([3]f32) * vertices.len;
        if (!buffer.create(
            &self.context,
            &self.context.grid_geometry_vertex_buffer,
            vertex_buffer_size,
            vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            buffer.MemoryFlags.host_visible,
        )) {
            logger.err("Failed to create grid vertex buffer", .{});
            return false;
        }

        // Upload vertex data directly to host-visible buffer
        _ = buffer.loadData(
            &self.context,
            &self.context.grid_geometry_vertex_buffer,
            0,
            vertex_buffer_size,
            &vertices,
        );

        // Create index buffer (use host-visible memory for simplicity)
        const index_buffer_size = @sizeOf(u32) * indices.len;
        if (!buffer.create(
            &self.context,
            &self.context.grid_geometry_index_buffer,
            index_buffer_size,
            vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
            buffer.MemoryFlags.host_visible,
        )) {
            logger.err("Failed to create grid index buffer", .{});
            buffer.destroy(&self.context, &self.context.grid_geometry_vertex_buffer);
            return false;
        }

        // Upload index data directly to host-visible buffer
        _ = buffer.loadData(
            &self.context,
            &self.context.grid_geometry_index_buffer,
            0,
            index_buffer_size,
            &indices,
        );

        logger.debug("Grid geometry created ({}x{} units).", .{ grid_size, grid_size });
        return true;
    }

    /// Render pass callback for grid rendering
    pub fn renderGridPass(pass_context: *const @import("../render_graph/executor.zig").RenderPassContext) void {
        // Get the backend pointer from user_data
        const backend_ptr: *VulkanBackend = @ptrCast(@alignCast(pass_context.pass.user_data.?));
        const cmd = backend_ptr.context.graphics_command_buffers[backend_ptr.context.image_index].handle;
        const current_frame = backend_ptr.context.current_frame;

        // Update camera UBO with current view-projection matrix
        if (renderer.getSystem()) |sys| {
            // FIXED: Use view * projection order to match rest of codebase (see editor.zig:339)
            const view_proj = math.mat4Mul(sys.view, sys.projection);
            var camera_ubo = renderer.GridCameraUBO.init();
            camera_ubo.view_proj = view_proj;

            _ = buffer.loadData(
                &backend_ptr.context,
                &backend_ptr.context.grid_camera_buffers[current_frame],
                0,
                @sizeOf(renderer.GridCameraUBO),
                &camera_ubo,
            );

            // Update grid UBO with camera position for fade
            var grid_ubo = renderer.GridUBO.initDefault();
            grid_ubo.camera_pos_x = sys.camera_position[0];
            grid_ubo.camera_pos_y = sys.camera_position[1];
            grid_ubo.camera_pos_z = sys.camera_position[2];

            _ = buffer.loadData(
                &backend_ptr.context,
                &backend_ptr.context.grid_ubo_buffers[current_frame],
                0,
                @sizeOf(renderer.GridUBO),
                &grid_ubo,
            );
        }

        // Bind grid pipeline
        vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, backend_ptr.context.grid_shader.pipeline.handle);

        // Bind descriptor set
        vk.vkCmdBindDescriptorSets(
            cmd,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            backend_ptr.context.grid_shader.pipeline.layout,
            0,
            1,
            &backend_ptr.context.grid_descriptor_state.sets[current_frame],
            0,
            null,
        );

        // Bind vertex buffer
        const vertex_buffers = [1]vk.VkBuffer{backend_ptr.context.grid_geometry_vertex_buffer.handle};
        const offsets = [1]vk.VkDeviceSize{0};
        vk.vkCmdBindVertexBuffers(cmd, 0, 1, &vertex_buffers, &offsets);

        // Bind index buffer
        vk.vkCmdBindIndexBuffer(cmd, backend_ptr.context.grid_geometry_index_buffer.handle, 0, vk.VK_INDEX_TYPE_UINT32);

        // Draw indexed
        vk.vkCmdDrawIndexed(cmd, backend_ptr.context.grid_geometry_index_count, 1, 0, 0, 0);
    }

    /// Render grid directly (called from endFrame, inside render pass)
    fn renderGridDirect(self: *VulkanBackend, cmd: vk.VkCommandBuffer, current_frame: u32) void {
        // Update camera UBO with current view-projection matrix
        if (renderer.getSystem()) |sys| {
            // FIXED: Use view * projection order to match rest of codebase (see editor.zig:339)
            const view_proj = math.mat4Mul(sys.view, sys.projection);
            var camera_ubo = renderer.GridCameraUBO.init();
            camera_ubo.view_proj = view_proj;

            _ = buffer.loadData(
                &self.context,
                &self.context.grid_camera_buffers[current_frame],
                0,
                @sizeOf(renderer.GridCameraUBO),
                &camera_ubo,
            );

            // Update grid UBO with camera position for fade
            var grid_ubo = renderer.GridUBO.initDefault();
            grid_ubo.camera_pos_x = sys.camera_position[0];
            grid_ubo.camera_pos_y = sys.camera_position[1];
            grid_ubo.camera_pos_z = sys.camera_position[2];

            _ = buffer.loadData(
                &self.context,
                &self.context.grid_ubo_buffers[current_frame],
                0,
                @sizeOf(renderer.GridUBO),
                &grid_ubo,
            );
        }

        // Bind grid pipeline
        vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.context.grid_shader.pipeline.handle);

        // Bind descriptor set
        vk.vkCmdBindDescriptorSets(
            cmd,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.context.grid_shader.pipeline.layout,
            0,
            1,
            &self.context.grid_descriptor_state.sets[current_frame],
            0,
            null,
        );

        // Bind vertex buffer
        const vertex_buffers = [1]vk.VkBuffer{self.context.grid_geometry_vertex_buffer.handle};
        const offsets = [1]vk.VkDeviceSize{0};
        vk.vkCmdBindVertexBuffers(cmd, 0, 1, &vertex_buffers, &offsets);

        // Bind index buffer
        vk.vkCmdBindIndexBuffer(cmd, self.context.grid_geometry_index_buffer.handle, 0, vk.VK_INDEX_TYPE_UINT32);

        // Draw indexed
        vk.vkCmdDrawIndexed(cmd, self.context.grid_geometry_index_count, 1, 0, 0, 0);
    }

    // --- Skybox rendering ---

    fn createSkyboxPipeline(self: *VulkanBackend, descriptor_layouts: []const vk.VkDescriptorSetLayout) bool {
        const allocator = std.heap.page_allocator;

        logger.debug("Creating skybox pipeline...", .{});

        // Load skybox vertex shader
        var vert_shader_module: shader.VulkanShaderModule = .{};
        if (!shader.load(
            &self.context,
            allocator,
            "build/shaders/Builtin.Skybox.vert.spv",
            .vertex,
            &vert_shader_module,
        )) {
            logger.err("Failed to load skybox vertex shader", .{});
            return false;
        }
        defer shader.destroy(&self.context, &vert_shader_module);

        // Load skybox fragment shader
        var frag_shader_module: shader.VulkanShaderModule = .{};
        if (!shader.load(
            &self.context,
            allocator,
            "build/shaders/Builtin.Skybox.frag.spv",
            .fragment,
            &frag_shader_module,
        )) {
            logger.err("Failed to load skybox fragment shader", .{});
            return false;
        }
        defer shader.destroy(&self.context, &frag_shader_module);

        // Shader stages
        var shader_stages: [2]vk.VkPipelineShaderStageCreateInfo = .{
            shader.createStageInfo(.{
                .module = vert_shader_module.handle,
                .stage = .vertex,
            }),
            shader.createStageInfo(.{
                .module = frag_shader_module.handle,
                .stage = .fragment,
            }),
        };

        // No vertex input (fullscreen triangle generated in shader)
        var vertex_input_info: vk.VkPipelineVertexInputStateCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };

        // Input assembly
        var input_assembly: vk.VkPipelineInputAssemblyStateCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vk.VK_FALSE,
        };

        // Viewport state (dynamic)
        var viewport_state: vk.VkPipelineViewportStateCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null,
            .scissorCount = 1,
            .pScissors = null,
        };

        // Rasterizer (no culling for skybox)
        var rasterizer: vk.VkPipelineRasterizationStateCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = vk.VK_FALSE,
            .rasterizerDiscardEnable = vk.VK_FALSE,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_NONE, // No culling for skybox
            .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = vk.VK_FALSE,
            .depthBiasConstantFactor = 0.0,
            .depthBiasClamp = 0.0,
            .depthBiasSlopeFactor = 0.0,
            .lineWidth = 1.0,
        };

        // Multisampling
        var multisampling: vk.VkPipelineMultisampleStateCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = vk.VK_FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = vk.VK_FALSE,
            .alphaToOneEnable = vk.VK_FALSE,
        };

        // Depth stencil (test enabled, write disabled, LESS_OR_EQUAL for far plane)
        var depth_stencil: vk.VkPipelineDepthStencilStateCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthTestEnable = vk.VK_TRUE,
            .depthWriteEnable = vk.VK_FALSE, // Don't write depth for skybox
            .depthCompareOp = vk.VK_COMPARE_OP_LESS_OR_EQUAL, // Draw at far plane
            .depthBoundsTestEnable = vk.VK_FALSE,
            .stencilTestEnable = vk.VK_FALSE,
            .front = std.mem.zeroes(vk.VkStencilOpState),
            .back = std.mem.zeroes(vk.VkStencilOpState),
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
        };

        // Color blending (no blending needed for skybox)
        var color_blend_attachment: vk.VkPipelineColorBlendAttachmentState = .{
            .blendEnable = vk.VK_FALSE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT |
                vk.VK_COLOR_COMPONENT_G_BIT |
                vk.VK_COLOR_COMPONENT_B_BIT |
                vk.VK_COLOR_COMPONENT_A_BIT,
        };

        var color_blending: vk.VkPipelineColorBlendStateCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = vk.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        // Dynamic state
        var dynamic_states = [_]vk.VkDynamicState{
            vk.VK_DYNAMIC_STATE_VIEWPORT,
            vk.VK_DYNAMIC_STATE_SCISSOR,
        };

        var dynamic_state: vk.VkPipelineDynamicStateCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        // Pipeline layout with 2 descriptor sets (Set 0: Global UBO, Set 3: Skybox cubemap)
        var pipeline_layout_info: vk.VkPipelineLayoutCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = @intCast(descriptor_layouts.len),
            .pSetLayouts = descriptor_layouts.ptr,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        var result = vk.vkCreatePipelineLayout(
            self.context.device,
            &pipeline_layout_info,
            self.context.allocator,
            &self.context.skybox_pipeline.layout,
        );

        if (result != vk.VK_SUCCESS) {
            logger.err("vkCreatePipelineLayout (skybox) failed: {}", .{result});
            return false;
        }

        // Create graphics pipeline
        var pipeline_info: vk.VkGraphicsPipelineCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state,
            .layout = self.context.skybox_pipeline.layout,
            .renderPass = self.context.main_renderpass.handle,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        result = vk.vkCreateGraphicsPipelines(
            self.context.device,
            null,
            1,
            &pipeline_info,
            self.context.allocator,
            &self.context.skybox_pipeline.handle,
        );

        if (result != vk.VK_SUCCESS) {
            logger.err("vkCreateGraphicsPipelines (skybox) failed: {}", .{result});
            vk.vkDestroyPipelineLayout(self.context.device, self.context.skybox_pipeline.layout, self.context.allocator);
            self.context.skybox_pipeline.layout = null;
            return false;
        }

        logger.info("Skybox pipeline created.", .{});
        return true;
    }

    fn renderSkybox(self: *VulkanBackend, cmd_buffer: vk.VkCommandBuffer, image_index: u32) void {
        const current_frame = self.context.current_frame;

        // Bind skybox pipeline
        pipeline.bindPipeline(cmd_buffer, &self.context.skybox_pipeline);

        // Bind descriptor sets
        // Set 0: Global UBO (camera matrices)
        vk.vkCmdBindDescriptorSets(
            cmd_buffer,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.context.skybox_pipeline.layout,
            0, // First set
            1,
            &self.context.global_descriptor_state.global_sets[current_frame],
            0,
            null,
        );

        // Set 1: Skybox cubemap
        vk.vkCmdBindDescriptorSets(
            cmd_buffer,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.context.skybox_pipeline.layout,
            1, // Set 1 (skybox cubemap)
            1,
            &self.context.skybox_descriptor_state.sets[image_index],
            0,
            null,
        );

        // Draw fullscreen triangle (3 vertices, no vertex buffer)
        vk.vkCmdDraw(cmd_buffer, 3, 1, 0, 0);
    }

    pub fn setSkyboxCubemap(self: *VulkanBackend, cubemap_texture: *resource_types.Texture) void {
        // Update all frame descriptor sets
        for (0..swapchain.MAX_SWAPCHAIN_IMAGES) |i| {
            descriptor.updateSkyboxSet(
                &self.context,
                &self.context.skybox_descriptor_state,
                @intCast(i),
                cubemap_texture,
            );
        }

        self.context.skybox_enabled = true;
        logger.info("Skybox cubemap set and enabled", .{});
    }

    pub fn disableSkybox(self: *VulkanBackend) void {
        self.context.skybox_enabled = false;
    }
};

/// Check if the required validation layers are available
fn checkValidationLayerSupport() bool {
    var layer_count: u32 = 0;
    _ = vk.vkEnumerateInstanceLayerProperties(&layer_count, null);

    if (layer_count == 0) {
        return false;
    }

    // Use a stack buffer for layer properties
    var available_layers: [64]vk.VkLayerProperties = undefined;
    if (layer_count > 64) {
        logger.warn("Too many validation layers to check ({} > 64)", .{layer_count});
        layer_count = 64;
    }

    _ = vk.vkEnumerateInstanceLayerProperties(&layer_count, &available_layers);

    // Check for VK_LAYER_KHRONOS_validation
    const required_layer = "VK_LAYER_KHRONOS_validation";
    for (available_layers[0..layer_count]) |layer| {
        const layer_name: [*:0]const u8 = @ptrCast(&layer.layerName);
        if (std.mem.eql(u8, std.mem.sliceTo(layer_name, 0), required_layer)) {
            logger.info("Found validation layer: {s}", .{required_layer});
            return true;
        }
    }

    logger.warn("Required validation layer not found: {s}", .{required_layer});
    return false;
}
