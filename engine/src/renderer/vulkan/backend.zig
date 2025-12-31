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

        // Create framebuffers (after renderpass is created)
        if (!swapchain.createFramebuffers(
            &self.context,
            &self.context.swapchain,
            self.context.main_renderpass.handle,
        )) {
            logger.err("Failed to create framebuffers.", .{});
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

        // Create descriptor set layout
        if (!descriptor.createGlobalLayout(&self.context, &self.context.descriptor_state)) {
            logger.err("Failed to create descriptor set layout.", .{});
            return false;
        }

        // Create descriptor pool
        if (!descriptor.createPool(
            &self.context,
            &self.context.descriptor_state,
            self.context.swapchain.max_frames_in_flight,
        )) {
            logger.err("Failed to create descriptor pool.", .{});
            return false;
        }

        // Allocate descriptor sets
        if (!descriptor.allocateSets(
            &self.context,
            &self.context.descriptor_state,
            self.context.swapchain.max_frames_in_flight,
        )) {
            logger.err("Failed to allocate descriptor sets.", .{});
            return false;
        }

        // Update descriptor sets with uniform buffer bindings
        self.updateDescriptorSets();

        // Load shaders
        if (!self.loadShaders()) {
            logger.err("Failed to load shaders.", .{});
            return false;
        }

        // Create graphics pipeline
        if (!pipeline.createMaterialPipeline(
            &self.context,
            &self.context.material_shader,
            self.context.descriptor_state.global_layout,
            self.context.main_renderpass.handle,
        )) {
            logger.err("Failed to create object shader pipeline.", .{});
            return false;
        }

        // Create default texture (white 1x1 texture)
        if (!self.createDefaultTexture()) {
            logger.err("Failed to create default texture.", .{});
            return false;
        }

        // Update descriptor sets with default texture
        self.updateDescriptorSetsWithTexture(&self.context.default_texture);

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

        // Destroy graphics pipeline
        pipeline.destroyMaterialPipeline(&self.context, &self.context.material_shader);

        // Destroy shaders
        shader.destroy(&self.context, &self.context.material_shader.vertex_shader);
        shader.destroy(&self.context, &self.context.material_shader.fragment_shader);

        // Destroy descriptor pool (also frees descriptor sets)
        descriptor.destroyPool(&self.context, &self.context.descriptor_state);

        // Destroy descriptor set layout
        descriptor.destroyGlobalLayout(&self.context, &self.context.descriptor_state);

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

        // Set up dynamic viewport and scissor
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

        // Begin the main renderpass - this transitions the image layout
        renderpass.begin(
            &self.context.main_renderpass,
            cmd_buffer.handle,
            self.context.swapchain.framebuffers[image_index],
        );

        // Mark frame as in progress (for texture binding safety)
        self.context.frame_in_progress = true;

        return true;
    }

    pub fn endFrame(self: *VulkanBackend, delta_time: f32) bool {
        _ = delta_time;

        const image_index = self.context.image_index;
        const current_frame = self.context.current_frame;

        const cmd_buffer = &self.context.graphics_command_buffers[image_index];

        // End the renderpass - this transitions the image to PRESENT_SRC layout
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

    /// Destroy a texture and free all associated resources
    pub fn destroyTexture(self: *VulkanBackend, tex: *resource_types.Texture) void {
        texture.destroy(&self.context, tex);
    }

    /// Bind a texture for rendering. Pass null to use the default texture from TextureSystem.
    /// This uses per-frame texture tracking to avoid redundant descriptor set updates.
    /// IMPORTANT: Texture binding during frame recording is deferred to avoid invalidating command buffers.
    pub fn bindTexture(self: *VulkanBackend, tex: ?*const resource_types.Texture) void {
        // If no texture provided, try to get default from TextureSystem, fall back to backend's default
        const texture_to_bind = tex orelse texture_system.getDefaultTexture() orelse &self.context.default_texture;
        const texture_id = texture_to_bind.id;

        // Check if this texture is already bound (check any frame since we update all)
        if (self.context.bound_texture_id[0] == texture_id) {
            return;
        }

        // If we're in the middle of a frame, we CANNOT safely update descriptor sets
        // because vkDeviceWaitIdle would invalidate the recording command buffer.
        // The game should bind textures before beginFrame, not during render.
        if (self.context.frame_in_progress) {
            // Skip the update - the currently bound texture will be used for this frame.
            // This is a design limitation: texture changes during frame recording are ignored.
            return;
        }

        // Not in a frame, safe to update all descriptor sets
        if (self.context.device != null) {
            _ = vk.vkDeviceWaitIdle(self.context.device);
        }
        self.updateDescriptorSetsWithTexture(texture_to_bind);
        // Mark all frames as having this texture bound
        for (&self.context.bound_texture_id) |*id| {
            id.* = texture_id;
        }
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

        // Bind the descriptor set for the current frame
        const descriptor_sets = [_]vk.VkDescriptorSet{
            self.context.descriptor_state.global_sets[current_frame],
        };
        vk.vkCmdBindDescriptorSets(
            cmd,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.context.material_shader.pipeline.layout,
            0,
            1,
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
                &self.context.descriptor_state,
                @intCast(i),
                &buffer_info,
            );
        }
    }

    fn updateDescriptorSetsWithTexture(self: *VulkanBackend, tex: *const resource_types.Texture) void {
        for (0..self.context.swapchain.max_frames_in_flight) |i| {
            descriptor.updateTextureSet(
                &self.context,
                &self.context.descriptor_state,
                @intCast(i),
                tex,
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

        logger.info("Default texture created ({}x{} checkerboard).", .{ texture_size, texture_size });
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

    /// Render ImGui draw data
    pub fn renderImGui(self: *VulkanBackend, draw_data: ?*anyopaque) void {
        if (!build_options.enable_imgui) return;
        if (!self.imgui_initialized) return;
        if (draw_data == null) return;

        // Get current command buffer
        const cmd_buf = self.context.graphics_command_buffers[self.context.image_index].handle;
        if (cmd_buf == null) return;

        // Cast draw_data with proper alignment and command buffer to imgui's type
        const imgui_draw_data: *imgui_vulkan.ImDrawData = @ptrCast(@alignCast(draw_data));
        imgui_vulkan.cImGui_ImplVulkan_RenderDrawData(imgui_draw_data, @ptrCast(cmd_buf));
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
