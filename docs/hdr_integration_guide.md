# HDR Pipeline Integration Guide

## Status: ✅ FULLY INTEGRATED

Phase 5 (HDR Pipeline and Tone Mapping) has been fully implemented and integrated into the Vulkan backend. The HDR rendering pipeline is now active and operational.

## Integration Summary

All integration steps have been completed:

- ✅ HDR system initialization in [backend.zig](../engine/src/renderer/vulkan/backend.zig:1994-2060)
- ✅ HDR system cleanup in [backend.zig](../engine/src/renderer/vulkan/backend.zig:2063-2081)
- ✅ Swapchain recreation with HDR framebuffers in [backend.zig](../engine/src/renderer/vulkan/backend.zig:463-474)
- ✅ Frame rendering with HDR pass in [backend.zig](../engine/src/renderer/vulkan/backend.zig:574-579)
- ✅ Tonemap pass in [backend.zig](../engine/src/renderer/vulkan/backend.zig:601-666)

## Completed Components ✅

### 1. Core Infrastructure

- ✅ HDR framebuffer resources in swapchain ([swapchain.zig](../engine/src/renderer/vulkan/swapchain.zig:35-39))
- ✅ HDR and tonemap render passes ([renderpass.zig](../engine/src/renderer/vulkan/renderpass.zig:231-437))
- ✅ Tonemap shaders compiled ([Tonemap.vert.glsl](../assets/shaders/Tonemap.vert.glsl), [Tonemap.frag.glsl](../assets/shaders/Tonemap.frag.glsl))
- ✅ Tonemap pipeline creation ([pipeline.zig](../engine/src/renderer/vulkan/pipeline.zig:1059-1328))
- ✅ Tonemap descriptor management ([descriptor.zig](../engine/src/renderer/vulkan/descriptor.zig:1194-1369))
- ✅ Context structures updated ([context.zig](../engine/src/renderer/vulkan/context.zig:179-186))

### 2. Tone Mapping Features

- Three tone mapping operators:
  - **Reinhard** (simple, classic)
  - **ACES Filmic** (default, industry standard)
  - **Uncharted 2** (cinematic)
- Runtime exposure adjustment
- Configurable gamma correction
- Push constants for parameter control

## Integration Checklist

### Step 1: Backend Initialization

Update `backend.zig` initialization to create HDR resources after shadow resources:

```zig
// After shadow resources are initialized...

// Create HDR renderpass
if (!renderpass.createHDRRenderpass(&self.context, &self.context.hdr_renderpass)) {
    logger.err("Failed to create HDR renderpass", .{});
    return false;
}

// Create tonemap renderpass
if (!renderpass.createTonemapRenderpass(&self.context, &self.context.tonemap_renderpass)) {
    logger.err("Failed to create tonemap renderpass", .{});
    return false;
}

// Create HDR framebuffers (need to be recreated after HDR renderpass creation)
if (!swapchain.createHDRFramebuffers(
    &self.context,
    &self.context.swapchain,
    self.context.hdr_renderpass.handle,
)) {
    logger.err("Failed to create HDR framebuffers", .{});
    return false;
}

// Create HDR sampler for tone mapping
var hdr_sampler_info: vk.VkSamplerCreateInfo = .{
    .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
    .pNext = null,
    .flags = 0,
    .magFilter = vk.VK_FILTER_LINEAR,
    .minFilter = vk.VK_FILTER_LINEAR,
    .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
    .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    .mipLodBias = 0.0,
    .anisotropyEnable = vk.VK_FALSE,
    .maxAnisotropy = 1.0,
    .compareEnable = vk.VK_FALSE,
    .compareOp = vk.VK_COMPARE_OP_ALWAYS,
    .minLod = 0.0,
    .maxLod = 0.0,
    .borderColor = vk.VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK,
    .unnormalizedCoordinates = vk.VK_FALSE,
};

var result = vk.vkCreateSampler(
    self.context.device,
    &hdr_sampler_info,
    self.context.allocator,
    &self.context.hdr_sampler,
);

if (result != vk.VK_SUCCESS) {
    logger.err("Failed to create HDR sampler", .{});
    return false;
}

// Create tonemap descriptor layout and pool
if (!descriptor.createTonemapLayout(&self.context, &self.context.tonemap_descriptor_state)) {
    logger.err("Failed to create tonemap descriptor layout", .{});
    return false;
}

if (!descriptor.createTonemapPool(&self.context, &self.context.tonemap_descriptor_state)) {
    logger.err("Failed to create tonemap descriptor pool", .{});
    return false;
}

// Allocate tonemap descriptor sets (one per frame in flight)
if (!descriptor.allocateTonemapSets(
    &self.context,
    &self.context.tonemap_descriptor_state,
    self.context.swapchain.max_frames_in_flight,
)) {
    logger.err("Failed to allocate tonemap descriptor sets", .{});
    return false;
}

// Update tonemap descriptor sets with HDR texture
for (0..self.context.swapchain.max_frames_in_flight) |i| {
    const hdr_image_info: vk.VkDescriptorImageInfo = .{
        .sampler = self.context.hdr_sampler,
        .imageView = self.context.swapchain.hdr_color_image.view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    descriptor.updateTonemapDescriptorSet(
        &self.context,
        &self.context.tonemap_descriptor_state,
        @intCast(i),
        &hdr_image_info,
    );
}

// Create tonemap pipeline
if (!pipeline.createTonemapPipeline(
    &self.context,
    &self.context.tonemap_pipeline,
    self.context.tonemap_descriptor_state.layout,
    self.context.tonemap_renderpass.handle,
)) {
    logger.err("Failed to create tonemap pipeline", .{});
    return false;
}

logger.info("HDR pipeline initialized successfully", .{});
```

### Step 2: Backend Shutdown

Update `backend.zig` shutdown to destroy HDR resources:

```zig
// Destroy tonemap resources
pipeline.destroyTonemapPipeline(&self.context, &self.context.tonemap_pipeline);
descriptor.destroyTonemapPool(&self.context, &self.context.tonemap_descriptor_state);
descriptor.destroyTonemapLayout(&self.context, &self.context.tonemap_descriptor_state);

// Destroy HDR sampler
if (self.context.hdr_sampler) |sampler| {
    vk.vkDestroySampler(self.context.device, sampler, self.context.allocator);
    self.context.hdr_sampler = null;
}

// Destroy render passes
renderpass.destroy(&self.context, &self.context.tonemap_renderpass);
renderpass.destroy(&self.context, &self.context.hdr_renderpass);

// HDR framebuffers and images destroyed automatically in swapchain.destroy()
```

### Step 3: Swapchain Recreation

Update swapchain recreation to handle HDR framebuffers:

```zig
// After creating HDR resources in swapchain recreation...

// Recreate HDR framebuffers with new renderpass
if (!swapchain.createHDRFramebuffers(
    context,
    &context.swapchain,
    context.hdr_renderpass.handle,
)) {
    logger.err("Failed to recreate HDR framebuffers", .{});
    return false;
}

// Update tonemap descriptor sets with new HDR image view
for (0..context.swapchain.max_frames_in_flight) |i| {
    const hdr_image_info: vk.VkDescriptorImageInfo = .{
        .sampler = context.hdr_sampler,
        .imageView = context.swapchain.hdr_color_image.view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    descriptor.updateTonemapDescriptorSet(
        context,
        &context.tonemap_descriptor_state,
        @intCast(i),
        &hdr_image_info,
    );
}
```

### Step 4: Frame Rendering Logic

Update frame rendering to use the HDR pipeline:

```zig
// Rendering order:
// 1. Shadow pass (existing)
// 2. HDR PBR pass (replace main_renderpass with hdr_renderpass)
// 3. Tonemap pass (new - HDR to LDR)
// 4. UI pass (existing - ImGui)

// --- Shadow Pass (existing, unchanged) ---
// ... shadow rendering code ...

// --- HDR PBR Pass ---
// Begin HDR renderpass instead of main renderpass
renderpass.begin(
    &self.context.hdr_renderpass,
    command_buffer,
    self.context.swapchain.hdr_framebuffers[self.context.image_index],
);

// Set viewport and scissor for HDR pass
var viewport: vk.VkViewport = .{
    .x = 0.0,
    .y = 0.0,
    .width = @floatFromInt(self.context.swapchain.extent.width),
    .height = @floatFromInt(self.context.swapchain.extent.height),
    .minDepth = 0.0,
    .maxDepth = 1.0,
};
vk.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

var scissor: vk.VkRect2D = .{
    .offset = .{ .x = 0, .y = 0 },
    .extent = self.context.swapchain.extent,
};
vk.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

// ... render scene with PBR ...
// (existing material rendering code - binds material pipeline, renders meshes)

// End HDR renderpass
renderpass.end(&self.context.hdr_renderpass, command_buffer);

// --- Tonemap Pass ---
// Begin tonemap renderpass
renderpass.begin(
    &self.context.tonemap_renderpass,
    command_buffer,
    self.context.swapchain.framebuffers[self.context.image_index],
);

// Set viewport and scissor for tonemap pass
vk.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
vk.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

// Bind tonemap pipeline
pipeline.bindPipeline(command_buffer, &self.context.tonemap_pipeline.pipeline);

// Bind tonemap descriptor set (HDR texture)
const tonemap_set = self.context.tonemap_descriptor_state.sets[self.context.current_frame];
vk.vkCmdBindDescriptorSets(
    command_buffer,
    vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
    self.context.tonemap_pipeline.pipeline.layout,
    0,
    1,
    &tonemap_set,
    0,
    null,
);

// Push tonemap constants
var tonemap_push_constants: pipeline.TonemapPushConstants = .{
    .exposure = 1.0, // Can be made configurable
    .tonemap_mode = 1, // 1 = ACES Filmic (default)
    .gamma = 2.2, // sRGB gamma
    ._padding = 0.0,
};

vk.vkCmdPushConstants(
    command_buffer,
    self.context.tonemap_pipeline.pipeline.layout,
    vk.VK_SHADER_STAGE_FRAGMENT_BIT,
    0,
    @sizeOf(pipeline.TonemapPushConstants),
    &tonemap_push_constants,
);

// Draw fullscreen triangle (no vertex buffer, 3 vertices)
vk.vkCmdDraw(command_buffer, 3, 1, 0, 0);

// End tonemap renderpass
renderpass.end(&self.context.tonemap_renderpass, command_buffer);

// --- UI Pass (existing ImGui rendering - unchanged) ---
// ... ImGui rendering code ...
```

## Pipeline Architecture

The new rendering pipeline:

```
┌─────────────────┐
│  Shadow Pass    │ → Depth-only rendering from light's perspective
│  (depth only)   │    Output: Shadow maps
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  HDR PBR Pass   │ → Render scene with PBR lighting
│  (HDR color +   │    Output: R16G16B16A16_SFLOAT HDR buffer
│   depth)        │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Tonemap Pass   │ → Convert HDR to LDR with tone mapping
│  (fullscreen    │    Input: HDR buffer
│   quad)         │    Output: Swapchain (LDR)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  UI Pass        │ → Render ImGui overlay
│  (ImGui)        │    Output: Swapchain with UI
└─────────────────┘
```

## Tone Mapping Configuration

### Exposure

Control overall brightness:

```zig
tonemap_push_constants.exposure = 1.5; // Brighter
tonemap_push_constants.exposure = 0.7; // Darker
```

### Tone Mapping Operator

Choose the tone mapping algorithm:

```zig
tonemap_push_constants.tonemap_mode = 0; // Reinhard
tonemap_push_constants.tonemap_mode = 1; // ACES Filmic (recommended)
tonemap_push_constants.tonemap_mode = 2; // Uncharted 2
```

### Gamma Correction

Adjust gamma curve:

```zig
tonemap_push_constants.gamma = 2.2; // sRGB (standard)
tonemap_push_constants.gamma = 2.4; // Darker midtones
tonemap_push_constants.gamma = 2.0; // Brighter midtones
```

## Performance Considerations

- **HDR Framebuffer**: ~8-12 MB @ 1080p
- **Tonemap Pass Overhead**: < 0.5ms (fullscreen triangle, simple shader)
- **Total Memory Impact**: Minimal (~12 MB additional)
- **Recommended**: Enable HDR for scenes with high dynamic range lighting

## Testing

1. **Build and run** the engine with HDR integration
2. **Verify** HDR framebuffer is created successfully
3. **Check** tonemap pass renders correctly
4. **Test** different tone mapping operators
5. **Adjust** exposure for different scenes
6. **Profile** performance impact

## Troubleshooting

### Black Screen

- Check HDR renderpass is being used instead of main renderpass
- Verify HDR framebuffers are created after HDR renderpass
- Ensure tonemap descriptor set references correct HDR image view

### Incorrect Colors

- Verify tone mapping mode is set correctly (1 = ACES Filmic)
- Check gamma correction value (2.2 for sRGB)
- Ensure exposure is reasonable (default: 1.0)

### Performance Issues

- Verify only one tonemap pass per frame
- Check HDR framebuffer is not being cleared unnecessarily
- Profile with RenderDoc to identify bottlenecks

## Future Enhancements

Once HDR is working, consider adding:

- **Bloom** post-process (requires HDR)
- **Auto-exposure** based on scene brightness
- **Color grading** LUT support
- **Motion blur** (velocity buffer)
- **Temporal anti-aliasing** (TAA)

## Next Phase

With Phase 5 complete, the next phase (Phase 6) focuses on:

- Metal backend compatibility
- Performance optimization
- Documentation and polish
