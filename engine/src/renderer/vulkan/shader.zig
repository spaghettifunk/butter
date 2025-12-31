//! Vulkan shader module management.
//!
//! Handles loading SPIR-V shaders and creating VkShaderModules.

const std = @import("std");
const vk_context = @import("context.zig");
const vk = vk_context.vk;
const logger = @import("../../core/logging.zig");
const filesystem = @import("../../platform/filesystem.zig");

/// Shader stage types
pub const ShaderStage = enum(u32) {
    vertex = vk.VK_SHADER_STAGE_VERTEX_BIT,
    fragment = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
    geometry = vk.VK_SHADER_STAGE_GEOMETRY_BIT,
    tessellation_control = vk.VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT,
    tessellation_evaluation = vk.VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT,
    compute = vk.VK_SHADER_STAGE_COMPUTE_BIT,
};

/// Vulkan shader module with metadata
pub const VulkanShaderModule = struct {
    handle: vk.VkShaderModule = null,
    stage: ShaderStage = .vertex,
};

/// Shader stage configuration for pipeline creation
pub const ShaderStageConfig = struct {
    module: vk.VkShaderModule,
    stage: ShaderStage,
    entry_point: [*:0]const u8 = "main",
};

/// Load a SPIR-V shader file and create a VkShaderModule
pub fn load(
    context: *vk_context.VulkanContext,
    allocator: std.mem.Allocator,
    shader_path: []const u8,
    stage: ShaderStage,
    out_module: *VulkanShaderModule,
) bool {
    // Open the shader file
    var file_handle: filesystem.FileHandle = .{};
    if (!filesystem.open(shader_path, .{ .read = true }, &file_handle)) {
        logger.err("Failed to open shader file: {s}", .{shader_path});
        return false;
    }
    defer filesystem.close(&file_handle);

    // Read all shader bytes
    const shader_code = filesystem.readAllBytes(&file_handle, allocator) orelse {
        logger.err("Failed to read shader file: {s}", .{shader_path});
        return false;
    };
    defer allocator.free(shader_code);

    // Validate SPIR-V code size (must be multiple of 4 bytes)
    if (shader_code.len == 0 or shader_code.len % 4 != 0) {
        logger.err("Invalid SPIR-V shader size: {} bytes (must be multiple of 4)", .{shader_code.len});
        return false;
    }

    // Create shader module
    var create_info: vk.VkShaderModuleCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = shader_code.len,
        .pCode = @ptrCast(@alignCast(shader_code.ptr)),
    };

    const result = vk.vkCreateShaderModule(
        context.device,
        &create_info,
        context.allocator,
        &out_module.handle,
    );

    if (result != vk.VK_SUCCESS) {
        logger.err("vkCreateShaderModule failed with result: {}", .{result});
        return false;
    }

    out_module.stage = stage;
    logger.debug("Shader module created: {s}", .{shader_path});
    return true;
}

/// Destroy a shader module
pub fn destroy(context: *vk_context.VulkanContext, shader_module: *VulkanShaderModule) void {
    if (context.device == null) return;

    if (shader_module.handle) |handle| {
        vk.vkDestroyShaderModule(context.device, handle, context.allocator);
        shader_module.handle = null;
    }
}

/// Create shader stage create info for pipeline creation
pub fn createStageInfo(config: ShaderStageConfig) vk.VkPipelineShaderStageCreateInfo {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = @intFromEnum(config.stage),
        .module = config.module,
        .pName = config.entry_point,
        .pSpecializationInfo = null,
    };
}
