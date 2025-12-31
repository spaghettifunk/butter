//! Vulkan physical device selection and management.

const std = @import("std");
const builtin = @import("builtin");
const vk_context = @import("context.zig");
const vk = vk_context.vk;
const logger = @import("../../core/logging.zig");

/// Select the best physical device for rendering
pub fn selectPhysicalDevice(context: *vk_context.VulkanContext) bool {
    logger.debug("Selecting physical device...", .{});

    // Enumerate physical devices
    var device_count: u32 = 0;
    _ = vk.vkEnumeratePhysicalDevices(context.instance, &device_count, null);

    if (device_count == 0) {
        logger.err("No GPUs with Vulkan support found!", .{});
        return false;
    }

    // Get all physical devices
    var devices: [16]vk.VkPhysicalDevice = undefined;
    if (device_count > 16) {
        logger.warn("More than 16 physical devices found, only checking first 16.", .{});
        device_count = 16;
    }
    _ = vk.vkEnumeratePhysicalDevices(context.instance, &device_count, &devices);

    logger.info("Found {} physical device(s).", .{device_count});

    // Find the best suitable device
    var best_device: ?vk.VkPhysicalDevice = null;
    var best_score: u32 = 0;

    for (devices[0..device_count]) |device| {
        const score = rateDeviceSuitability(context, device);
        if (score > best_score) {
            best_score = score;
            best_device = device;
        }
    }

    if (best_device == null or best_score == 0) {
        logger.err("Failed to find a suitable GPU!", .{});
        return false;
    }

    // Unwrap the optional since we verified it's not null
    const selected_device = best_device.?;
    context.physical_device = selected_device;

    // Get device properties and features
    vk.vkGetPhysicalDeviceProperties(selected_device, &context.physical_device_properties);
    vk.vkGetPhysicalDeviceFeatures(selected_device, &context.physical_device_features);
    vk.vkGetPhysicalDeviceMemoryProperties(selected_device, &context.physical_device_memory_properties);

    // Get queue family indices
    context.queue_family_indices = findQueueFamilies(context, selected_device);

    // Query swapchain support
    querySwapchainSupport(context, selected_device);

    const device_name: [*:0]const u8 = @ptrCast(&context.physical_device_properties.deviceName);
    const device_type_str = switch (context.physical_device_properties.deviceType) {
        vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => "Discrete GPU",
        vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => "Integrated GPU",
        vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => "Virtual GPU",
        vk.VK_PHYSICAL_DEVICE_TYPE_CPU => "CPU",
        else => "Other",
    };

    logger.info("Selected GPU: {s} ({s})", .{ device_name, device_type_str });
    logger.debug("Graphics queue family: {?}, Present queue family: {?}", .{
        context.queue_family_indices.graphics_family,
        context.queue_family_indices.present_family,
    });

    // Log detailed GPU information
    logDeviceInfo(context);

    return true;
}

/// Rate a physical device's suitability for rendering
fn rateDeviceSuitability(context: *vk_context.VulkanContext, device: vk.VkPhysicalDevice) u32 {
    var properties: vk.VkPhysicalDeviceProperties = undefined;
    var features: vk.VkPhysicalDeviceFeatures = undefined;

    vk.vkGetPhysicalDeviceProperties(device, &properties);
    vk.vkGetPhysicalDeviceFeatures(device, &features);

    var score: u32 = 0;

    // Discrete GPUs have a significant performance advantage
    if (properties.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
        score += 1000;
    } else if (properties.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) {
        score += 100;
    }

    // Maximum possible size of textures affects graphics quality
    score += properties.limits.maxImageDimension2D;

    // Check for required queue families
    const indices = findQueueFamilies(context, device);
    if (!indices.isComplete()) {
        return 0; // Device doesn't have required queue families
    }

    // Check for required device extensions
    if (!checkDeviceExtensionSupport(device)) {
        return 0; // Device doesn't support required extensions
    }

    // Check swapchain support
    var swapchain_support: vk_context.SwapchainSupportDetails = .{};
    querySwapchainSupportForDevice(context, device, &swapchain_support);
    if (swapchain_support.format_count == 0 or swapchain_support.present_mode_count == 0) {
        return 0; // Swapchain not adequate
    }

    // Prefer devices with geometry shader support (optional feature)
    if (features.geometryShader != 0) {
        score += 100;
    }

    // Prefer devices with sampler anisotropy
    if (features.samplerAnisotropy != 0) {
        score += 50;
    }

    const device_name: [*:0]const u8 = @ptrCast(&properties.deviceName);
    logger.debug("Device '{s}' scored: {}", .{ device_name, score });

    return score;
}

/// Find queue families that support graphics, presentation, compute, and transfer
pub fn findQueueFamilies(context: *vk_context.VulkanContext, physical_device: vk.VkPhysicalDevice) vk_context.QueueFamilyIndices {
    var indices: vk_context.QueueFamilyIndices = .{};

    var queue_family_count: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);

    var queue_families: [64]vk.VkQueueFamilyProperties = undefined;
    if (queue_family_count > 64) {
        queue_family_count = 64;
    }
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, &queue_families);

    // First pass: find graphics, present, and any compute/transfer queues
    for (queue_families[0..queue_family_count], 0..) |queue_family, i| {
        const idx: u32 = @intCast(i);
        const flags = queue_family.queueFlags;

        // Check for graphics support
        if ((flags & vk.VK_QUEUE_GRAPHICS_BIT) != 0) {
            indices.graphics_family = idx;
        }

        // Check for present support
        var present_support: vk.VkBool32 = vk.VK_FALSE;
        _ = vk.vkGetPhysicalDeviceSurfaceSupportKHR(physical_device, idx, context.surface, &present_support);
        if (present_support == vk.VK_TRUE) {
            indices.present_family = idx;
        }

        // Check for compute support (prefer dedicated compute queue without graphics)
        if ((flags & vk.VK_QUEUE_COMPUTE_BIT) != 0) {
            if (indices.compute_family == null) {
                indices.compute_family = idx;
            } else if ((flags & vk.VK_QUEUE_GRAPHICS_BIT) == 0) {
                // Found a dedicated compute queue (no graphics), prefer this
                indices.compute_family = idx;
            }
        }

        // Check for transfer support (prefer dedicated transfer queue)
        if ((flags & vk.VK_QUEUE_TRANSFER_BIT) != 0) {
            if (indices.transfer_family == null) {
                indices.transfer_family = idx;
            } else if ((flags & vk.VK_QUEUE_GRAPHICS_BIT) == 0 and (flags & vk.VK_QUEUE_COMPUTE_BIT) == 0) {
                // Found a dedicated transfer queue (no graphics or compute), prefer this
                indices.transfer_family = idx;
            }
        }
    }

    // If no dedicated compute queue found but graphics supports compute, use graphics
    if (indices.compute_family == null and indices.graphics_family != null) {
        const graphics_idx = indices.graphics_family.?;
        if ((queue_families[graphics_idx].queueFlags & vk.VK_QUEUE_COMPUTE_BIT) != 0) {
            indices.compute_family = graphics_idx;
        }
    }

    // If no dedicated transfer queue found, use graphics (graphics queues implicitly support transfer)
    if (indices.transfer_family == null and indices.graphics_family != null) {
        indices.transfer_family = indices.graphics_family;
    }

    return indices;
}

/// Check if a device supports the required extensions
fn checkDeviceExtensionSupport(device: vk.VkPhysicalDevice) bool {
    var extension_count: u32 = 0;
    _ = vk.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, null);

    var available_extensions: [256]vk.VkExtensionProperties = undefined;
    if (extension_count > 256) {
        extension_count = 256;
    }
    _ = vk.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, &available_extensions);

    // Required device extensions
    const required_extensions = [_][*:0]const u8{
        vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
    };

    for (required_extensions) |required| {
        var found = false;
        for (available_extensions[0..extension_count]) |available| {
            const ext_name: [*:0]const u8 = @ptrCast(&available.extensionName);
            if (std.mem.eql(u8, std.mem.sliceTo(ext_name, 0), std.mem.sliceTo(required, 0))) {
                found = true;
                break;
            }
        }
        if (!found) {
            return false;
        }
    }

    return true;
}

/// Query swapchain support for the selected device and store in context
pub fn querySwapchainSupport(context: *vk_context.VulkanContext, device: vk.VkPhysicalDevice) void {
    querySwapchainSupportForDevice(context, device, &context.swapchain_support);
}

/// Query swapchain support details for a specific device
pub fn querySwapchainSupportForDevice(context: *vk_context.VulkanContext, device: vk.VkPhysicalDevice, details: *vk_context.SwapchainSupportDetails) void {
    // Get surface capabilities
    _ = vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, context.surface, &details.capabilities);

    // Get surface formats
    _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(device, context.surface, &details.format_count, null);
    if (details.format_count > 0) {
        if (details.format_count > 32) {
            details.format_count = 32;
        }
        _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(device, context.surface, &details.format_count, &details.formats);
    }

    // Get present modes
    _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(device, context.surface, &details.present_mode_count, null);
    if (details.present_mode_count > 0) {
        if (details.present_mode_count > 16) {
            details.present_mode_count = 16;
        }
        _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(device, context.surface, &details.present_mode_count, &details.present_modes);
    }
}

/// Create the logical device and retrieve queue handles
pub fn createLogicalDevice(context: *vk_context.VulkanContext) bool {
    logger.debug("Creating logical device...", .{});

    const indices = context.queue_family_indices;
    if (!indices.isComplete()) {
        logger.err("Queue family indices are not complete!", .{});
        return false;
    }

    const graphics_family = indices.graphics_family.?;
    const present_family = indices.present_family.?;
    const compute_family = indices.compute_family;
    const transfer_family = indices.transfer_family;

    // Collect unique queue family indices
    // Maximum 4 unique families: graphics, present, compute, transfer
    var unique_families: [4]u32 = undefined;
    var unique_family_count: u32 = 0;

    // Helper to add unique family
    const addUniqueFamily = struct {
        fn add(families: *[4]u32, count: *u32, family: u32) void {
            for (families[0..count.*]) |existing| {
                if (existing == family) return;
            }
            families[count.*] = family;
            count.* += 1;
        }
    }.add;

    // Add all queue families
    addUniqueFamily(&unique_families, &unique_family_count, graphics_family);
    addUniqueFamily(&unique_families, &unique_family_count, present_family);
    if (compute_family) |cf| {
        addUniqueFamily(&unique_families, &unique_family_count, cf);
    }
    if (transfer_family) |tf| {
        addUniqueFamily(&unique_families, &unique_family_count, tf);
    }

    // Create queue create infos for each unique family
    var queue_create_infos: [4]vk.VkDeviceQueueCreateInfo = undefined;
    const queue_priority: f32 = 1.0;

    for (unique_families[0..unique_family_count], 0..) |family, i| {
        queue_create_infos[i] = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };
    }

    // Log queue family configuration
    logger.debug("Queue families: graphics={}, present={}, compute={?}, transfer={?}", .{
        graphics_family,
        present_family,
        compute_family,
        transfer_family,
    });
    logger.debug("Using {} unique queue family(ies)", .{unique_family_count});

    // Specify device features we want to enable
    var device_features: vk.VkPhysicalDeviceFeatures = std.mem.zeroes(vk.VkPhysicalDeviceFeatures);

    // Enable sampler anisotropy if available
    if (context.physical_device_features.samplerAnisotropy != 0) {
        device_features.samplerAnisotropy = vk.VK_TRUE;
    }

    // Required device extensions
    const device_extensions = [_][*:0]const u8{
        vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
        // On macOS with MoltenVK, we may need portability subset
        if (builtin.os.tag == .macos) "VK_KHR_portability_subset" else vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
    };

    // Filter out duplicates (in case swapchain is listed twice on non-macOS)
    var unique_extensions: [2][*:0]const u8 = undefined;
    var unique_count: u32 = 0;
    for (device_extensions) |ext| {
        var is_duplicate = false;
        for (unique_extensions[0..unique_count]) |existing| {
            if (std.mem.eql(u8, std.mem.sliceTo(ext, 0), std.mem.sliceTo(existing, 0))) {
                is_duplicate = true;
                break;
            }
        }
        if (!is_duplicate) {
            unique_extensions[unique_count] = ext;
            unique_count += 1;
        }
    }

    // Create the logical device
    var create_info: vk.VkDeviceCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueCreateInfoCount = unique_family_count,
        .pQueueCreateInfos = &queue_create_infos,
        .enabledLayerCount = 0, // Device layers are deprecated
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = unique_count,
        .ppEnabledExtensionNames = &unique_extensions,
        .pEnabledFeatures = &device_features,
    };

    const result = vk.vkCreateDevice(context.physical_device, &create_info, context.allocator, &context.device);
    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateDevice failed with result: {}", .{result});
        return false;
    }

    logger.info("Logical device created.", .{});

    // Retrieve queue handles
    vk.vkGetDeviceQueue(context.device, graphics_family, 0, &context.graphics_queue);
    vk.vkGetDeviceQueue(context.device, present_family, 0, &context.present_queue);

    // Retrieve compute queue (may be same as graphics)
    if (compute_family) |cf| {
        vk.vkGetDeviceQueue(context.device, cf, 0, &context.compute_queue);
        if (indices.hasDedicatedCompute()) {
            logger.debug("Retrieved dedicated compute queue from family {}", .{cf});
        } else {
            logger.debug("Using graphics queue for compute (family {})", .{cf});
        }
    }

    // Retrieve transfer queue (may be same as graphics or compute)
    if (transfer_family) |tf| {
        vk.vkGetDeviceQueue(context.device, tf, 0, &context.transfer_queue);
        if (indices.hasDedicatedTransfer()) {
            logger.debug("Retrieved dedicated transfer queue from family {}", .{tf});
        } else {
            logger.debug("Using shared queue for transfer (family {})", .{tf});
        }
    }

    logger.debug("Retrieved graphics queue from family {}", .{graphics_family});
    logger.debug("Retrieved present queue from family {}", .{present_family});

    return true;
}

/// Destroy the logical device
pub fn destroyLogicalDevice(context: *vk_context.VulkanContext) void {
    if (context.device == null) return;

    logger.debug("Destroying logical device...", .{});

    // Wait for device to be idle before destroying
    _ = vk.vkDeviceWaitIdle(context.device);

    vk.vkDestroyDevice(context.device, context.allocator);
    context.device = null;
    context.graphics_queue = null;
    context.present_queue = null;
    context.compute_queue = null;
    context.transfer_queue = null;

    logger.debug("Logical device destroyed.", .{});
}

/// Log detailed GPU information using trace level
fn logDeviceInfo(context: *vk_context.VulkanContext) void {
    const props = &context.physical_device_properties;
    const features = &context.physical_device_features;
    const mem_props = &context.physical_device_memory_properties;

    // Device properties
    const device_name: [*:0]const u8 = @ptrCast(&props.deviceName);
    logger.trace("=== GPU Device Properties ===", .{});
    logger.trace("  Device Name: {s}", .{device_name});
    logger.trace("  API Version: {}.{}.{}", .{
        (props.apiVersion >> 22) & 0x7F,
        (props.apiVersion >> 12) & 0x3FF,
        props.apiVersion & 0xFFF,
    });
    logger.trace("  Driver Version: {}", .{props.driverVersion});
    logger.trace("  Vendor ID: 0x{X:0>4}", .{props.vendorID});
    logger.trace("  Device ID: 0x{X:0>4}", .{props.deviceID});

    // Device limits
    logger.trace("=== GPU Limits ===", .{});
    logger.trace("  Max Image Dimension 2D: {}", .{props.limits.maxImageDimension2D});
    logger.trace("  Max Image Dimension 3D: {}", .{props.limits.maxImageDimension3D});
    logger.trace("  Max Uniform Buffer Range: {}", .{props.limits.maxUniformBufferRange});
    logger.trace("  Max Storage Buffer Range: {}", .{props.limits.maxStorageBufferRange});
    logger.trace("  Max Push Constants Size: {}", .{props.limits.maxPushConstantsSize});
    logger.trace("  Max Memory Allocation Count: {}", .{props.limits.maxMemoryAllocationCount});
    logger.trace("  Max Bound Descriptor Sets: {}", .{props.limits.maxBoundDescriptorSets});
    logger.trace("  Max Vertex Input Attributes: {}", .{props.limits.maxVertexInputAttributes});
    logger.trace("  Max Vertex Input Bindings: {}", .{props.limits.maxVertexInputBindings});
    logger.trace("  Max Framebuffer Width: {}", .{props.limits.maxFramebufferWidth});
    logger.trace("  Max Framebuffer Height: {}", .{props.limits.maxFramebufferHeight});
    logger.trace("  Max Viewports: {}", .{props.limits.maxViewports});

    // Device features
    logger.trace("=== GPU Features ===", .{});
    logger.trace("  Geometry Shader: {}", .{features.geometryShader != 0});
    logger.trace("  Tessellation Shader: {}", .{features.tessellationShader != 0});
    logger.trace("  Sampler Anisotropy: {}", .{features.samplerAnisotropy != 0});
    logger.trace("  Texture Compression ETC2: {}", .{features.textureCompressionETC2 != 0});
    logger.trace("  Texture Compression ASTC_LDR: {}", .{features.textureCompressionASTC_LDR != 0});
    logger.trace("  Texture Compression BC: {}", .{features.textureCompressionBC != 0});
    logger.trace("  Multi Draw Indirect: {}", .{features.multiDrawIndirect != 0});
    logger.trace("  Draw Indirect First Instance: {}", .{features.drawIndirectFirstInstance != 0});
    logger.trace("  Depth Clamp: {}", .{features.depthClamp != 0});
    logger.trace("  Depth Bias Clamp: {}", .{features.depthBiasClamp != 0});
    logger.trace("  Fill Mode Non Solid: {}", .{features.fillModeNonSolid != 0});
    logger.trace("  Wide Lines: {}", .{features.wideLines != 0});
    logger.trace("  Large Points: {}", .{features.largePoints != 0});

    // Memory properties
    logger.trace("=== GPU Memory Properties ===", .{});
    logger.trace("  Memory Type Count: {}", .{mem_props.memoryTypeCount});
    logger.trace("  Memory Heap Count: {}", .{mem_props.memoryHeapCount});

    // Log memory heaps
    for (0..mem_props.memoryHeapCount) |i| {
        const heap = mem_props.memoryHeaps[i];
        const size_mb = heap.size / (1024 * 1024);
        const is_device_local = (heap.flags & vk.VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) != 0;
        if (is_device_local) {
            logger.trace("  Heap {}: {} MB (Device Local)", .{ i, size_mb });
        } else {
            logger.trace("  Heap {}: {} MB", .{ i, size_mb });
        }
    }

    // Log memory types
    for (0..mem_props.memoryTypeCount) |i| {
        const mem_type = mem_props.memoryTypes[i];
        const is_device_local = (mem_type.propertyFlags & vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0;
        const is_host_visible = (mem_type.propertyFlags & vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0;
        const is_host_coherent = (mem_type.propertyFlags & vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
        const is_host_cached = (mem_type.propertyFlags & vk.VK_MEMORY_PROPERTY_HOST_CACHED_BIT) != 0;

        logger.trace("  Type {}: Heap {} [{c}{c}{c}{c}]", .{
            i,
            mem_type.heapIndex,
            @as(u8, if (is_device_local) 'D' else '-'),
            @as(u8, if (is_host_visible) 'V' else '-'),
            @as(u8, if (is_host_coherent) 'C' else '-'),
            @as(u8, if (is_host_cached) 'H' else '-'),
        });
    }
    logger.trace("  (D=DeviceLocal, V=HostVisible, C=HostCoherent, H=HostCached)", .{});
}
