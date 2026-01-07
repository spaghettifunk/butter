# Implementation Plan: PBR and Shadow Mapping for Butter Engine

## Overview

This plan outlines a phased implementation of Physically Based Rendering (PBR) with Image-Based Lighting (IBL) and comprehensive shadow mapping for the Butter game engine. The implementation will replace the existing Blinn-Phong lighting model while maintaining compatibility with both Vulkan and Metal backends.

## Current Architecture Summary

**Strengths:**

- Two-tier descriptor architecture: Set 0 (GlobalUBO), Set 1 (Material textures)
- Push constants with 128 bytes (model matrix, material params with roughness/metallic placeholders)
- Vertex format includes tangent vectors (ready for normal mapping)
- Material system with `.bmt` config files and reference counting
- GlobalUBO at 496 bytes with capacity for expansion

**Current Lighting:**

- Blinn-Phong shading model
- 1 directional light + up to 8 point lights
- Diffuse and specular maps

## Implementation Phases

### Phase 1: PBR Shader Foundation (Weeks 1-2)

**Goal:** Replace Blinn-Phong with Cook-Torrance BRDF and add normal mapping

**Shader Changes:**

1. **Vertex Shader** ([Builtin.MaterialShader.vert.glsl](assets/shaders/Builtin.MaterialShader.vert.glsl))

   - Calculate TBN matrix for tangent-space normal mapping
   - Output tangent and bitangent vectors to fragment shader

2. **Fragment Shader** ([Builtin.MaterialShader.frag.glsl](assets/shaders/Builtin.MaterialShader.frag.glsl))
   - Replace Blinn-Phong with Cook-Torrance BRDF:
     - GGX normal distribution function
     - Schlick-GGX geometry function (Smith model)
     - Fresnel-Schlick for surface reflections
   - Add normal mapping with TBN matrix
   - Extend material textures from 2 to 8 bindings:
     - Binding 0: Albedo (replaces diffuse)
     - Binding 1: Metallic-Roughness (packed: G=roughness, B=metallic)
     - Binding 2: Normal map
     - Binding 3: Ambient Occlusion
     - Binding 4: Emissive
     - Binding 5: Irradiance cubemap (for IBL)
     - Binding 6: Prefiltered environment cubemap (for IBL)
     - Binding 7: BRDF LUT (2D lookup texture)
   - Implement PBR lighting functions:
     - `getNormalFromMap()` - Normal mapping
     - `DistributionGGX()` - Normal distribution
     - `GeometrySmith()` - Geometry occlusion
     - `fresnelSchlick()` - Fresnel reflection
     - `calculatePBR()` - Main BRDF evaluation
     - `calculateIBL()` - Image-based lighting (added in Phase 2)

**Backend Changes:**

3. **Vulkan Descriptors** ([engine/src/renderer/vulkan/descriptor.zig](engine/src/renderer/vulkan/descriptor.zig))

   - Extend `createMaterialLayout()` to support 8 texture bindings (was 2)
   - Update descriptor pool sizes: `MAX_MATERIAL_DESCRIPTORS * 8`
   - Add cubemap sampler support for IBL textures

4. **Texture System** ([engine/src/renderer/vulkan/texture.zig](engine/src/renderer/vulkan/texture.zig))
   - Add `createCubemap()` function for cubemap creation
   - Support 6-face cubemap layout
   - Enable mipmap generation for prefiltered environment maps

**Material System:**

5. **Material Types** ([engine/src/resources/types.zig](engine/src/resources/types.zig))

   - Extend `TextureUse` enum with PBR types:
     - `TEXTURE_USE_MAP_ALBEDO`
     - `TEXTURE_USE_MAP_METALLIC_ROUGHNESS`
     - `TEXTURE_USE_MAP_NORMAL`
     - `TEXTURE_USE_MAP_AO`
     - `TEXTURE_USE_MAP_EMISSIVE`
     - `TEXTURE_USE_MAP_IRRADIANCE`
     - `TEXTURE_USE_MAP_PREFILTERED`
     - `TEXTURE_USE_MAP_BRDF_LUT`
   - Update `Material` struct with PBR texture maps and parameters:
     - `albedo_map`, `metallic_roughness_map`, `normal_map`, `ao_map`, `emissive_map`
     - `roughness: f32`, `metallic: f32`, `emissive_strength: f32`

6. **Material System** ([engine/src/systems/material.zig](engine/src/systems/material.zig))
   - Update `.bmt` file parser for new PBR texture keys
   - Update `allocateMaterialDescriptorSet()` to bind 8 textures
   - Extended `.bmt` format:
     ```
     name=my_material
     base_color=1.0,1.0,1.0,1.0
     albedo_map=../assets/textures/albedo.png
     metallic_roughness_map=../assets/textures/metallic_roughness.png
     normal_map=../assets/textures/normal.png
     ao_map=../assets/textures/ao.png
     emissive_map=../assets/textures/emissive.png
     roughness=0.8
     metallic=0.2
     emissive_strength=0.0
     ```

**Testing:**

- Create test materials with PBR textures
- Verify Cook-Torrance BRDF against reference renders
- Test normal mapping on various geometries
- Compare with Blinn-Phong baseline

---

### Phase 2: Image-Based Lighting (Week 3)

**Goal:** Add environment-based ambient lighting and reflections

**New Systems:**

7. **Environment System** ([engine/src/systems/environment.zig](engine/src/systems/environment.zig) - **NEW FILE**)
   - Manage IBL resources (irradiance maps, prefiltered maps, BRDF LUT)
   - Load HDR environment maps (equirectangular `.hdr` format)
   - Generate/load precomputed IBL textures:
     - Irradiance map: 32×32 cubemap (diffuse IBL)
     - Prefiltered environment: 512×512 cubemap with 5 mip levels (specular IBL)
     - BRDF LUT: 512×512 2D texture (R16G16 format)
   - Provide default procedural environment (gradient sky)
   - Key functions:
     - `initialize()` - Create default environment
     - `loadFromHDR(path)` - Load custom environment
     - `getDefaultIBL()` - Get IBL textures for rendering

**IBL Generation Strategy:**

- **Offline generation (recommended):** Use cmgen (Filament) to precompute IBL maps
- Store in `/assets/environments/` directory
- Load as regular cubemap textures at runtime
- BRDF LUT: Use pre-generated texture (commit to repo)

**Shader Updates:**

8. **Fragment Shader IBL** ([Builtin.MaterialShader.frag.glsl](assets/shaders/Builtin.MaterialShader.frag.glsl))
   - Implement `calculateIBL()` function:
     - Sample irradiance map for diffuse ambient
     - Sample prefiltered map with roughness-based LOD for specular reflections
     - Use BRDF LUT for split-sum approximation
     - Combine with Fresnel for energy conservation
   - Apply ambient occlusion to IBL contribution
   - Add IBL to final lighting: `color = ambient + Lo + emissive`

**Testing:**

- Test with multiple HDR environments
- Verify specular reflections vary with roughness
- Compare against reference PBR renders (Marmoset, Substance)

---

### Phase 3: Cascade Shadow Maps for Directional Lights (Weeks 4-5)

**Goal:** Add high-quality shadow mapping for the main directional light

**Shadow System:**

9. **Shadow System** ([engine/src/renderer/shadow_system.zig](engine/src/renderer/shadow_system.zig) - **NEW FILE**)
   - Manage shadow map rendering and resources
   - Key structures:
     - `CascadeShadowMap`: 2048×2048 depth texture, framebuffer, view-projection matrix, split depth
     - `ShadowSystem`: 4 cascades, shadow render pass, descriptor sets
   - Functions:
     - `initialize()` - Create shadow resources
     - `renderShadowMaps(scene)` - Render depth from light's perspective
     - `calculateCascadeSplits(near, far)` - Logarithmic split calculation
     - `calculateCascadeMatrices(camera, light)` - Light-space matrices for each cascade

**Uniform Buffer Extension:**

10. **Shadow UBO** ([engine/src/renderer/renderer.zig](engine/src/renderer/renderer.zig))
    - Add new `ShadowUBO` struct (Set 0, binding 1) - 320 bytes:
      - `cascade_view_proj: [4]Mat4` - Light-space matrices (256 bytes)
      - `cascade_splits: [4]f32` - Split distances (16 bytes)
      - Shadow parameters: bias, slope bias, PCF samples (16 bytes)
      - Shadow enable flags (16 bytes)
      - Point light shadow indices (16 bytes)
    - Keep existing `GlobalUBO` unchanged (Set 0, binding 0)

**Descriptor Sets:**

11. **Global Descriptor Update** ([engine/src/renderer/vulkan/descriptor.zig](engine/src/renderer/vulkan/descriptor.zig))
    - Add ShadowUBO as second binding in Set 0
    - Create Set 2 for shadow map textures:
      - Binding 0: `sampler2DArray` for directional cascades (4 layers)
      - Binding 1: `samplerCubeArray` for point light shadows (added in Phase 4)

**Shadow Shaders:**

12. **Shadow Map Shaders** (**NEW FILES**)
    - [assets/shaders/ShadowMap.vert.glsl](assets/shaders/ShadowMap.vert.glsl):
      - Transform vertices with cascade view-projection matrix
      - Use push constant for cascade index
    - [assets/shaders/ShadowMap.frag.glsl](assets/shaders/ShadowMap.frag.glsl):
      - Empty (depth written automatically)

**Shadow Render Pass:**

13. **Render Pass System** ([engine/src/renderer/vulkan/renderpass.zig](engine/src/renderer/vulkan/renderpass.zig))
    - Add `createShadowRenderpass()`:
      - Depth attachment only (D32_SFLOAT)
      - Load op: CLEAR, Store op: STORE
      - Final layout: SHADER_READ_ONLY_OPTIMAL

**Shadow Sampling:**

14. **Fragment Shader Shadow Sampling** ([Builtin.MaterialShader.frag.glsl](assets/shaders/Builtin.MaterialShader.frag.glsl))
    - Add descriptor set 2 bindings for shadow maps
    - Implement shadow sampling functions:
      - `getCascadeIndex(depth)` - Select cascade based on view depth
      - `sampleDirectionalShadow(world_pos, normal, light_dir)`:
        - Transform to light space
        - Select cascade
        - Apply depth bias (shadow acne prevention)
        - PCF filtering (4×4 samples)
        - Return visibility (0=shadowed, 1=lit)
    - Apply shadows to directional light: `Lo += calculatePBR(...) * shadow`

**Cascade Split Strategy:**

- 4 cascades with logarithmic splits (lambda=0.95)
- Covers near-medium-far-very far ranges
- Tight orthographic projection around frustum corners

**Testing:**

- Visualize cascades with debug colors
- Test shadow acne and peter-panning fixes
- Verify coverage across entire view frustum
- Performance profiling of shadow pass

---

### Phase 4: Point Light Shadow Maps (Week 6)

**Goal:** Add omnidirectional shadows for point lights

**Shadow System Extension:**

15. **Point Light Shadows** ([engine/src/renderer/shadow_system.zig](engine/src/renderer/shadow_system.zig))
    - Add `PointShadowMap` structure:
      - Depth cubemap: 1024×1024×6 faces
      - 6 framebuffers (one per face)
      - 6 view-projection matrices
      - Light ID association
    - Limit to 4 shadowing point lights (performance/memory)
    - Render 6 faces per point light (±X, ±Y, ±Z directions)

**Shadow Sampling:**

16. **Point Shadow Sampling** ([Builtin.MaterialShader.frag.glsl](assets/shaders/Builtin.MaterialShader.frag.glsl))
    - Implement `samplePointShadow(world_pos, light_index)`:
      - Calculate fragment-to-light vector
      - Sample cubemap with direction
      - Compare depth with bias
      - Return visibility
    - Apply to point lights: `Lo += pbr_contribution * shadow`

**Testing:**

- Test with 1-4 shadowing point lights
- Verify omnidirectional shadows
- Performance impact analysis
- Memory usage monitoring

---

### Phase 5: HDR Pipeline and Tone Mapping (Week 7)

**Goal:** Enable high dynamic range rendering with tone mapping post-process

**HDR Render Target:**

17. **Swapchain Extension** ([engine/src/renderer/vulkan/swapchain.zig](engine/src/renderer/vulkan/swapchain.zig))
    - Add HDR framebuffer resources:
      - `hdr_color_image`: R16G16B16A16_SFLOAT
      - `hdr_color_view`: VkImageView
      - `hdr_framebuffers`: One per swapchain image
    - Main pass renders to HDR target instead of swapchain

**Render Pass Restructure:**

18. **HDR Render Pass** ([engine/src/renderer/vulkan/renderpass.zig](engine/src/renderer/vulkan/renderpass.zig))
    - Add `createHDRRenderpass()`:
      - Color attachment: R16G16B16A16_SFLOAT (HDR)
      - Depth attachment: D32_SFLOAT
      - Final layout: SHADER_READ_ONLY_OPTIMAL
    - Add `createTonemapRenderpass()`:
      - Color attachment: swapchain format (LDR)
      - No depth
      - Fullscreen quad rendering

**New Render Pipeline:**

1. Shadow pass (depth only)
2. Main PBR pass (HDR output)
3. Tone mapping pass (HDR → LDR)
4. UI pass (ImGui overlay)

**Tone Mapping Shaders:**

19. **Tone Mapping** (**NEW FILES**)
    - [assets/shaders/Tonemap.vert.glsl](assets/shaders/Tonemap.vert.glsl):
      - Fullscreen triangle (no vertex buffer)
    - [assets/shaders/Tonemap.frag.glsl](assets/shaders/Tonemap.frag.glsl):
      - Sample HDR color texture
      - Apply exposure adjustment
      - Apply tone mapping operator:
        - Option 0: Reinhard
        - Option 1: ACES Filmic (recommended)
        - Option 2: Uncharted 2
      - Gamma correction (sRGB)
      - Output LDR color to swapchain

**Frame Rendering Update:**

20. **Backend Frame Logic** ([engine/src/renderer/vulkan/backend.zig](engine/src/renderer/vulkan/backend.zig))
    - Update `beginFrame()`:
      - Render shadow maps first
      - Begin HDR pass
    - Update `endFrame()`:
      - End HDR pass
      - Render tone mapping pass
      - Render UI pass
      - Submit and present

**Testing:**

- Test with high dynamic range scenes (bright lights, dark areas)
- Compare tone mapping operators
- Verify exposure control
- Bloom-ready output validation

---

### Phase 6: Metal Backend and Polish (Week 8)

**Goal:** Ensure full Metal backend compatibility and optimization

**Metal Backend:**

21. **Metal Shader Translation** ([engine/build/shaders/\*.msl](engine/build/shaders/*.msl))

    - Update build.zig to compile new shaders (shadow, tonemap)
    - Verify GLSL → SPIR-V → MSL translation
    - Test descriptor set mapping to argument buffers
    - Verify cubemap sampling (`textureCube` in MSL)
    - Shadow samplers: `depth2d<float>` with compare function

22. **Metal Descriptor Management** ([engine/src/renderer/metal/backend.zig](engine/src/renderer/metal/backend.zig))
    - Update `allocateMaterialDescriptorSet()` for 8 textures
    - Add IBL cubemap binding
    - Add shadow map texture binding (Set 2 equivalent)
    - Update frame rendering pipeline to match Vulkan

**Optimization:**

23. **Performance Optimization**
    - Profile shadow pass overhead
    - Measure fragment shader cost
    - Optimize PCF sample count
    - Consider shadow map caching for static geometry
    - Memory usage tracking and optimization

**Documentation:**

24. **Documentation** (**NEW FILES**)
    - PBR material authoring guide
    - IBL environment setup instructions
    - Shadow quality configuration
    - Performance tuning guide

**Testing:**

- Full cross-platform testing (Vulkan + Metal)
- Performance profiling on both backends
- Visual parity verification
- Stress testing with complex scenes

---

## Technical Decisions

### Descriptor Set Architecture

- **Set 0:** GlobalUBO (binding 0) + ShadowUBO (binding 1)
- **Set 1:** Material textures (8 bindings)
- **Set 2:** Shadow maps (directional cascades + point cubemaps)

### Shadow Map Configuration

- Directional cascades: 4 × 2048×2048 (64 MB total)
- Point light shadows: 4 lights × 1024×1024×6 faces (96 MB total)
- PCF filtering: 4×4 samples (configurable)

### IBL Strategy

- Offline generation using cmgen (Filament tool)
- Pre-generated BRDF LUT (committed to repo)
- Default procedural environment as fallback

### Tone Mapping

- Default: ACES Filmic (industry standard)
- Alternatives: Reinhard, Uncharted 2
- Configurable via push constants

### Performance Budget

- Total GPU memory: ~230-260 MB (textures + framebuffers)
- Target frame time: 15-20ms @ 1080p on mid-range GPU

---

## Critical Files to Modify

### Shaders (5 files)

1. [assets/shaders/Builtin.MaterialShader.vert.glsl](assets/shaders/Builtin.MaterialShader.vert.glsl)
2. [assets/shaders/Builtin.MaterialShader.frag.glsl](assets/shaders/Builtin.MaterialShader.frag.glsl)
3. [assets/shaders/ShadowMap.vert.glsl](assets/shaders/ShadowMap.vert.glsl) (**NEW**)
4. [assets/shaders/ShadowMap.frag.glsl](assets/shaders/ShadowMap.frag.glsl) (**NEW**)
5. [assets/shaders/Tonemap.vert.glsl](assets/shaders/Tonemap.vert.glsl) (**NEW**)
6. [assets/shaders/Tonemap.frag.glsl](assets/shaders/Tonemap.frag.glsl) (**NEW**)

### Core Systems (2 files)

7. [engine/src/renderer/renderer.zig](engine/src/renderer/renderer.zig) - GlobalUBO, ShadowUBO
8. [engine/src/resources/types.zig](engine/src/resources/types.zig) - Material struct, TextureUse enum

### New Systems (2 files)

9. [engine/src/systems/environment.zig](engine/src/systems/environment.zig) (**NEW**) - IBL management
10. [engine/src/renderer/shadow_system.zig](engine/src/renderer/shadow_system.zig) (**NEW**) - Shadow mapping

### Vulkan Backend (7 files)

11. [engine/src/renderer/vulkan/backend.zig](engine/src/renderer/vulkan/backend.zig) - Frame rendering
12. [engine/src/renderer/vulkan/descriptor.zig](engine/src/renderer/vulkan/descriptor.zig) - Descriptor sets
13. [engine/src/renderer/vulkan/pipeline.zig](engine/src/renderer/vulkan/pipeline.zig) - Pipeline state
14. [engine/src/renderer/vulkan/renderpass.zig](engine/src/renderer/vulkan/renderpass.zig) - Render passes
15. [engine/src/renderer/vulkan/swapchain.zig](engine/src/renderer/vulkan/swapchain.zig) - HDR target
16. [engine/src/renderer/vulkan/texture.zig](engine/src/renderer/vulkan/texture.zig) - Cubemap support
17. [engine/src/renderer/vulkan/context.zig](engine/src/renderer/vulkan/context.zig) - Context updates

### Metal Backend (1 file)

18. [engine/src/renderer/metal/backend.zig](engine/src/renderer/metal/backend.zig) - Metal compatibility

### Material System (2 files)

19. [engine/src/systems/material.zig](engine/src/systems/material.zig) - Material loading
20. [engine/src/systems/light.zig](engine/src/systems/light.zig) - Light system updates

### Resources (1 file)

21. [engine/src/resources/manager.zig](engine/src/resources/manager.zig) - Resource loading

### Build (1 file)

22. [engine/build.zig](engine/build.zig) - Shader compilation

---

## Risk Mitigation

**High-Risk Areas:**

1. **Shadow artifacts** - Extensive bias tuning, expose as material parameter
2. **Descriptor exhaustion** - Pool monitoring, dynamic recreation
3. **Metal parity** - Early testing, parallel development
4. **Performance** - Profiling at each phase, quality settings

**Testing Strategy:**

- Unit tests: Cascade splits, shadow matrices, tone mapping
- Integration tests: Material loading, shadow rendering, IBL
- Visual tests: Reference comparisons, glTF sample models
- Performance tests: Frame time, memory usage

---

## Dependencies

**Required Tools:**

- **cmgen** (Filament) - IBL map generation
- **spirv-cross** - Shader cross-compilation (already in use)
- **HDR environments** - Test assets (Poly Haven, HDRI Haven)

**Optional Tools:**

- RenderDoc - Vulkan debugging
- Nsight Graphics - NVIDIA profiling
- Xcode Metal Debugger - Metal verification

---

## Timeline Summary

- **Week 1-2:** PBR shader foundation (BRDF, normal mapping, material system)
- **Week 3:** Image-Based Lighting (IBL resources, environment system)
- **Week 4-5:** Cascade shadow maps (directional lights, PCF filtering)
- **Week 6:** Point light shadows (cubemap shadows)
- **Week 7:** HDR pipeline and tone mapping
- **Week 8:** Metal backend compatibility and polish

**Total:** 8 weeks for complete PBR and shadow implementation

---

## Success Criteria

✅ PBR materials render with physically accurate lighting
✅ Normal maps add surface detail
✅ IBL provides realistic ambient lighting and reflections
✅ Directional light casts high-quality cascaded shadows
✅ Point lights cast omnidirectional shadows
✅ HDR tone mapping produces cinematic output
✅ Both Vulkan and Metal backends fully functional
✅ Performance targets met (50-60 FPS @ 1080p mid-range GPU)
✅ Material authoring workflow documented

---

## Future Enhancements (Post-Implementation)

- Screen-Space Reflections (SSR)
- Bloom post-process
- Ambient Occlusion (SSAO/HBAO)
- Subsurface Scattering (SSS)
- Volumetric lighting
- Dynamic IBL probes
- Contact-hardening shadows (PCSS)
