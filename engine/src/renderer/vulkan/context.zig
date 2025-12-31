//! Vulkan context - holds all Vulkan-specific state.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const logger = @import("../../core/logging.zig");
const swapchain = @import("swapchain.zig");
const renderpass = @import("renderpass.zig");
const command_buffer = @import("command_buffer.zig");
const pipeline = @import("pipeline.zig");
const buffer = @import("buffer.zig");
const descriptor = @import("descriptor.zig");
const resource_types = @import("../../resources/types.zig");

// Pure Vulkan import - no GLFW dependency (safe for game library)
pub const vk = @cImport({
    @cInclude("vulkan/vulkan.h");
});

// Enable validation based on build options (controlled by build.zig)
pub const enable_validation = build_options.enable_validation;

/// Queue family indices for graphics, presentation, compute, and transfer
pub const QueueFamilyIndices = struct {
    graphics_family: ?u32 = null,
    present_family: ?u32 = null,
    compute_family: ?u32 = null,
    transfer_family: ?u32 = null,

    /// Check if required queue families (graphics and present) are available
    pub fn isComplete(self: QueueFamilyIndices) bool {
        return self.graphics_family != null and self.present_family != null;
    }

    /// Check if a dedicated compute queue is available (different from graphics)
    pub fn hasDedicatedCompute(self: QueueFamilyIndices) bool {
        return self.compute_family != null and self.compute_family != self.graphics_family;
    }

    /// Check if a dedicated transfer queue is available (different from graphics and compute)
    pub fn hasDedicatedTransfer(self: QueueFamilyIndices) bool {
        return self.transfer_family != null and
            self.transfer_family != self.graphics_family and
            self.transfer_family != self.compute_family;
    }
};

/// Swapchain support details
pub const SwapchainSupportDetails = struct {
    capabilities: vk.VkSurfaceCapabilitiesKHR = undefined,
    format_count: u32 = 0,
    formats: [32]vk.VkSurfaceFormatKHR = undefined,
    present_mode_count: u32 = 0,
    present_modes: [16]vk.VkPresentModeKHR = undefined,
};

pub const VulkanContext = struct {
    instance: vk.VkInstance = null,
    allocator: ?*vk.VkAllocationCallbacks = null,
    debug_messenger: vk.VkDebugUtilsMessengerEXT = null,
    surface: vk.VkSurfaceKHR = null,

    // Physical device
    physical_device: vk.VkPhysicalDevice = null,
    physical_device_properties: vk.VkPhysicalDeviceProperties = undefined,
    physical_device_features: vk.VkPhysicalDeviceFeatures = undefined,
    physical_device_memory_properties: vk.VkPhysicalDeviceMemoryProperties = undefined,
    queue_family_indices: QueueFamilyIndices = .{},
    swapchain_support: SwapchainSupportDetails = .{},

    // Logical device and queues
    device: vk.VkDevice = null,
    graphics_queue: vk.VkQueue = null,
    present_queue: vk.VkQueue = null,
    compute_queue: vk.VkQueue = null,
    transfer_queue: vk.VkQueue = null,

    // Swapchain
    swapchain: swapchain.VulkanSwapchain = .{},

    // Renderpass
    main_renderpass: renderpass.VulkanRenderpass = .{},

    // Command pool and buffers
    graphics_command_pool: vk.VkCommandPool = null,
    graphics_command_buffers: [swapchain.MAX_SWAPCHAIN_IMAGES]command_buffer.VulkanCommandBuffer =
        [_]command_buffer.VulkanCommandBuffer{.{}} ** swapchain.MAX_SWAPCHAIN_IMAGES,

    // Synchronization objects (per frame in flight)
    image_available_semaphores: [swapchain.MAX_SWAPCHAIN_IMAGES]vk.VkSemaphore =
        [_]vk.VkSemaphore{null} ** swapchain.MAX_SWAPCHAIN_IMAGES,
    render_complete_semaphores: [swapchain.MAX_SWAPCHAIN_IMAGES]vk.VkSemaphore =
        [_]vk.VkSemaphore{null} ** swapchain.MAX_SWAPCHAIN_IMAGES,
    in_flight_fences: [swapchain.MAX_SWAPCHAIN_IMAGES]vk.VkFence =
        [_]vk.VkFence{null} ** swapchain.MAX_SWAPCHAIN_IMAGES,
    images_in_flight: [swapchain.MAX_SWAPCHAIN_IMAGES]vk.VkFence =
        [_]vk.VkFence{null} ** swapchain.MAX_SWAPCHAIN_IMAGES,

    // Framebuffer dimensions (updated on resize)
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,

    // Current frame state
    current_frame: u32 = 0,
    image_index: u32 = 0,
    recreating_swapchain: bool = false,
    frame_in_progress: bool = false,

    // Currently bound texture per frame (to avoid redundant descriptor set updates)
    bound_texture_id: [swapchain.MAX_SWAPCHAIN_IMAGES]u32 = [_]u32{0xFFFFFFFF} ** swapchain.MAX_SWAPCHAIN_IMAGES,

    // Material shader and pipeline
    material_shader: pipeline.MaterialShader = .{},

    // Descriptor state
    descriptor_state: descriptor.MaterialShaderDescriptorState = .{},

    // Global uniform buffers (one per frame in flight)
    global_uniform_buffers: [swapchain.MAX_SWAPCHAIN_IMAGES]buffer.VulkanBuffer =
        [_]buffer.VulkanBuffer{.{}} ** swapchain.MAX_SWAPCHAIN_IMAGES,

    // Default texture (white 1x1 texture used when no texture is bound)
    default_texture: resource_types.Texture = .{
        .id = 0,
        .width = 0,
        .height = 0,
        .channel_count = 0,
        .has_transparency = false,
        .generation = 0,
        .internal_data = null,
    },
};

/// Vulkan debug callback - called by validation layers
pub fn debugCallback(
    message_severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_types: vk.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data: [*c]const vk.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vk.VkBool32 {
    _ = message_types;
    _ = user_data;

    const message: [*:0]const u8 = if (callback_data.*.pMessage) |msg| msg else "No message";

    if (message_severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        logger.err("[Vulkan] {s}", .{message});
    } else if (message_severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        logger.warn("[Vulkan] {s}", .{message});
    } else if (message_severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) {
        logger.info("[Vulkan] {s}", .{message});
    } else {
        logger.debug("[Vulkan] {s}", .{message});
    }

    return vk.VK_FALSE;
}

// Portability extension flag for macOS (MoltenVK)
pub const VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR: u32 = 0x00000001;

// Function pointer types for debug messenger
pub const PFN_vkCreateDebugUtilsMessengerEXT = *const fn (
    vk.VkInstance,
    [*c]const vk.VkDebugUtilsMessengerCreateInfoEXT,
    [*c]const vk.VkAllocationCallbacks,
    [*c]vk.VkDebugUtilsMessengerEXT,
) callconv(.c) vk.VkResult;

pub const PFN_vkDestroyDebugUtilsMessengerEXT = *const fn (
    vk.VkInstance,
    vk.VkDebugUtilsMessengerEXT,
    [*c]const vk.VkAllocationCallbacks,
) callconv(.c) void;
