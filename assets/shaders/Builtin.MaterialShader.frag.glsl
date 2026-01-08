#version 450
#extension GL_ARB_separate_shader_objects : enable

layout(set = 0, binding = 0) uniform GlobalUBO {
    // Matrices (128 bytes)
    mat4 projection;
    mat4 view;

    // Camera data (16 bytes)
    vec3 camera_position;
    float _pad0;

    // Directional light (32 bytes)
    vec3 dir_light_direction;
    float dir_light_intensity;
    vec3 dir_light_color;
    float dir_light_enabled;

    // Point light count (16 bytes, vec4 aligned)
    uint point_light_count;
    float _pad_lights1;
    float _pad_lights2;
    float _pad_lights3;

    // Point lights array (8 lights * 32 bytes = 256 bytes)
    vec4 point_lights[16]; // Each light uses 2 vec4s: [pos.xyz, range], [color.rgb, intensity]

    // Screen/viewport data (16 bytes)
    vec2 screen_size;
    float near_plane;
    float far_plane;

    // Time data (16 bytes)
    float time;
    float delta_time;
    uint frame_count;
    float _pad1;

    // Ambient lighting (16 bytes)
    vec4 ambient_color;
} ubo;

// Shadow UBO (Set 0, Binding 1)
layout(set = 0, binding = 1) uniform ShadowUBO {
    mat4 cascade_view_proj[4];    // Light-space matrices for each cascade
    vec4 cascade_splits;           // Split distances
    vec4 shadow_params;            // bias, slope_bias, pcf_samples, enabled
    vec4 point_shadow_enabled;     // Point light shadow flags
    vec4 point_shadow_indices;     // Point light shadow indices
} shadow_ubo;

// Shadow map textures (Set 2)
layout(set = 2, binding = 0) uniform sampler2D cascade_shadow_maps[4]; // 4 cascade shadow maps
layout(set = 2, binding = 1) uniform samplerCube point_shadow_cubemaps[4]; // Point light shadow cubemaps

// PBR Material textures (Set 1)
layout(set = 1, binding = 0) uniform sampler2D albedo_sampler;
layout(set = 1, binding = 1) uniform sampler2D metallic_roughness_sampler; // G=roughness, B=metallic
layout(set = 1, binding = 2) uniform sampler2D normal_sampler;
layout(set = 1, binding = 3) uniform sampler2D ao_sampler;
layout(set = 1, binding = 4) uniform sampler2D emissive_sampler;
layout(set = 1, binding = 5) uniform sampler2D irradiance_map;          // Diffuse IBL (2D placeholder until cubemap support)
layout(set = 1, binding = 6) uniform sampler2D prefiltered_map;         // Specular IBL (2D placeholder until cubemap support)
layout(set = 1, binding = 7) uniform sampler2D brdf_lut;                // BRDF LUT

// Push constants (need to match vertex shader, but we only access material params)
layout(push_constant) uniform PushConstants {
    layout(offset = 64) vec4 tint_color;         // 16 bytes - material tint color
    layout(offset = 80) vec4 material_params;    // 16 bytes - roughness, metallic, emission, pad
    // Note: We skip model matrix (64 bytes) and UV transform (16 bytes) which are vertex-only
} push;

layout(location = 0) in vec4 frag_color;
layout(location = 1) in vec2 frag_texcoord;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_pos;
layout(location = 4) in vec3 frag_tangent;
layout(location = 5) in vec3 frag_bitangent;

layout(location = 0) out vec4 out_color;

const float PI = 3.14159265359;

// =============================================================================
// Normal Mapping
// =============================================================================

vec3 getNormalFromMap(vec2 uv, vec3 tangent, vec3 bitangent, vec3 normal) {
    // Sample normal map (tangent space)
    vec3 tangent_normal = texture(normal_sampler, uv).xyz * 2.0 - 1.0;

    // Construct TBN matrix
    mat3 TBN = mat3(tangent, bitangent, normal);

    // Transform from tangent space to world space
    return normalize(TBN * tangent_normal);
}

// =============================================================================
// PBR Functions (Cook-Torrance BRDF)
// =============================================================================

// GGX Normal Distribution Function
float DistributionGGX(vec3 N, vec3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;

    float num = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;

    return num / denom;
}

// Schlick-GGX Geometry Function
float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;

    float num = NdotV;
    float denom = NdotV * (1.0 - k) + k;

    return num / denom;
}

// Smith's method (combines viewing and light directions)
float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);

    return ggx1 * ggx2;
}

// Fresnel-Schlick approximation
vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// Fresnel-Schlick with roughness for IBL
vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness) {
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// =============================================================================
// PBR Lighting Calculation
// =============================================================================

vec3 calculatePBR(vec3 N, vec3 V, vec3 L, vec3 H, vec3 albedo, float metallic, float roughness, vec3 F0, vec3 radiance) {
    // Cook-Torrance BRDF
    float NDF = DistributionGGX(N, H, roughness);
    float G = GeometrySmith(N, V, L, roughness);
    vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);

    vec3 kS = F;
    vec3 kD = vec3(1.0) - kS;
    kD *= 1.0 - metallic; // Metallic surfaces have no diffuse

    vec3 numerator = NDF * G * F;
    float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.0001; // Add epsilon to prevent division by zero
    vec3 specular = numerator / denominator;

    // Add to outgoing radiance Lo
    float NdotL = max(dot(N, L), 0.0);
    return (kD * albedo / PI + specular) * radiance * NdotL;
}

// =============================================================================
// Image-Based Lighting (IBL)
// =============================================================================

vec3 calculateIBL(vec3 N, vec3 V, vec3 albedo, float metallic, float roughness, vec3 F0, float ao) {
    // Calculate Fresnel with roughness for IBL
    float NdotV = max(dot(N, V), 0.0);
    vec3 F = fresnelSchlickRoughness(NdotV, F0, roughness);

    // Energy conservation - what doesn't reflect is diffuse
    vec3 kS = F;
    vec3 kD = 1.0 - kS;
    kD *= 1.0 - metallic; // Metallic surfaces have no diffuse

    // Diffuse IBL - sample irradiance map (2D placeholder - sample center for now)
    // TODO: Replace with proper cubemap sampling when cubemap support is added
    vec3 irradiance = texture(irradiance_map, vec2(0.5, 0.5)).rgb;
    vec3 diffuse = irradiance * albedo;

    // Specular IBL - sample prefiltered environment map (2D placeholder - sample center for now)
    // TODO: Replace with proper cubemap sampling and LOD selection when cubemap support is added
    vec3 prefilteredColor = texture(prefiltered_map, vec2(0.5, 0.5)).rgb;

    // Sample BRDF LUT for split-sum approximation
    // X axis: NdotV, Y axis: roughness
    vec2 envBRDF = texture(brdf_lut, vec2(NdotV, roughness)).rg;
    vec3 specular = prefilteredColor * (F * envBRDF.x + envBRDF.y);

    // Combine diffuse and specular with ambient occlusion
    return (kD * diffuse + specular) * ao;
}

// =============================================================================
// Shadow Mapping
// =============================================================================

// Select which cascade to use based on view-space depth
int getCascadeIndex(float view_depth) {
    // Compare view depth against cascade splits
    for (int i = 0; i < 4; i++) {
        if (view_depth < shadow_ubo.cascade_splits[i]) {
            return i;
        }
    }
    return 3; // Use last cascade if beyond all splits
}

// Sample directional light shadow with PCF filtering
float sampleDirectionalShadow(vec3 world_pos, vec3 normal, vec3 light_dir) {
    // Check if shadows are enabled
    if (shadow_ubo.shadow_params.w < 0.5) {
        return 1.0; // No shadow
    }

    // Calculate view-space depth for cascade selection
    vec4 view_pos = ubo.view * vec4(world_pos, 1.0);
    float view_depth = abs(view_pos.z);

    // Select cascade
    int cascade_index = getCascadeIndex(view_depth);

    // Transform to light space
    vec4 light_space_pos = shadow_ubo.cascade_view_proj[cascade_index] * vec4(world_pos, 1.0);

    // Perform perspective divide
    vec3 proj_coords = light_space_pos.xyz / light_space_pos.w;

    // Transform to [0,1] range for texture sampling
    proj_coords = proj_coords * 0.5 + 0.5;

    // Check if fragment is outside shadow map bounds
    if (proj_coords.x < 0.0 || proj_coords.x > 1.0 ||
        proj_coords.y < 0.0 || proj_coords.y > 1.0 ||
        proj_coords.z > 1.0) {
        return 1.0; // Outside shadow map, no shadow
    }

    // Depth bias to prevent shadow acne
    float bias = shadow_ubo.shadow_params.x;
    float slope_bias = shadow_ubo.shadow_params.y;

    // Calculate slope-based bias
    float NdotL = max(dot(normal, light_dir), 0.0);
    float total_bias = bias + slope_bias * (1.0 - NdotL);

    // PCF (Percentage Closer Filtering) - 4x4 samples
    float shadow = 0.0;
    vec2 texel_size = 1.0 / textureSize(cascade_shadow_maps[cascade_index], 0);

    for (int x = -2; x <= 1; x++) {
        for (int y = -2; y <= 1; y++) {
            vec2 offset = vec2(x, y) * texel_size;
            float pcf_depth = texture(cascade_shadow_maps[cascade_index], proj_coords.xy + offset).r;
            shadow += (proj_coords.z - total_bias) > pcf_depth ? 1.0 : 0.0;
        }
    }
    shadow /= 16.0; // Average over 4x4 samples

    // Return visibility (1.0 = fully lit, 0.0 = fully shadowed)
    return 1.0 - shadow;
}

// Sample point light shadow with cubemap
float samplePointShadow(vec3 world_pos, uint light_index, vec3 light_pos, float light_range) {
    // Check if this point light has shadows enabled
    if (shadow_ubo.point_shadow_enabled[light_index] < 0.5) {
        return 1.0; // No shadow
    }

    // Get shadow map index for this point light
    int shadow_index = int(shadow_ubo.point_shadow_indices[light_index]);
    if (shadow_index < 0 || shadow_index >= 4) {
        return 1.0; // Invalid shadow index
    }

    // Calculate fragment-to-light vector
    vec3 frag_to_light = world_pos - light_pos;

    // Sample cubemap depth
    float closest_depth = texture(point_shadow_cubemaps[shadow_index], frag_to_light).r;

    // Convert to linear depth (closest_depth is in [0,1] range from perspective projection)
    // For cubemap shadows, we need to compare distances
    float current_depth = length(frag_to_light);

    // Depth bias to prevent shadow acne
    float bias = shadow_ubo.shadow_params.x * 0.5; // Use half the bias for point lights

    // Convert closest_depth from [0,1] to actual distance
    // This assumes the shadow map was rendered with near=0.1, far=light_range
    const float near = 0.1;
    float far = light_range;
    float depth = closest_depth * far;

    // Compare depths
    float shadow = (current_depth - bias) > depth ? 1.0 : 0.0;

    // Return visibility (1.0 = fully lit, 0.0 = fully shadowed)
    return 1.0 - shadow;
}

void main() {
    // Sample PBR textures
    // Note: Albedo texture uses SRGB format, so GPU automatically converts to linear space
    vec3 albedo = texture(albedo_sampler, frag_texcoord).rgb;

    // Apply tint color (should be white [1,1,1] for normal materials)
    albedo *= push.tint_color.rgb * frag_color.rgb;

    vec2 metallic_roughness = texture(metallic_roughness_sampler, frag_texcoord).gb;
    float roughness = clamp(metallic_roughness.r * push.material_params.x, 0.04, 1.0);
    float metallic = metallic_roughness.g * push.material_params.y;

    float ao = texture(ao_sampler, frag_texcoord).r;
    vec3 emissive = texture(emissive_sampler, frag_texcoord).rgb * push.material_params.z;

    // Normal mapping
    vec3 N = getNormalFromMap(frag_texcoord, frag_tangent, frag_bitangent, frag_normal);
    vec3 V = normalize(ubo.camera_position - frag_pos);

    // Calculate F0 (surface reflection at zero incidence)
    // For dielectrics (non-metals), F0 is typically 0.04
    // For metals, F0 is the albedo color
    vec3 F0 = vec3(0.04);
    F0 = mix(F0, albedo, metallic);

    // Direct lighting accumulation
    vec3 Lo = vec3(0.0);

    // Directional light with shadows
    if (ubo.dir_light_enabled > 0.5) {
        vec3 L = normalize(-ubo.dir_light_direction);
        vec3 H = normalize(V + L);
        vec3 radiance = ubo.dir_light_color * ubo.dir_light_intensity;

        // Sample shadow map
        float shadow = sampleDirectionalShadow(frag_pos, N, L);

        Lo += calculatePBR(N, V, L, H, albedo, metallic, roughness, F0, radiance) * shadow;
    }

    // Point lights with shadows
    for (uint i = 0u; i < ubo.point_light_count && i < 8u; i++) {
        uint idx = i * 2u;
        vec3 light_pos = ubo.point_lights[idx].xyz;
        float light_range = ubo.point_lights[idx].w;
        vec3 light_color = ubo.point_lights[idx + 1u].xyz;
        float light_intensity = ubo.point_lights[idx + 1u].w;

        if (light_intensity > 0.0) {
            // Calculate per-light radiance
            vec3 L = light_pos - frag_pos;
            float distance = length(L);
            L = normalize(L);
            vec3 H = normalize(V + L);

            // Attenuation (inverse square law with range limit)
            float attenuation = 1.0 / (distance * distance);
            attenuation *= smoothstep(light_range, light_range * 0.5, distance);

            vec3 radiance = light_color * light_intensity * attenuation;

            // Sample point shadow map
            float shadow = samplePointShadow(frag_pos, i, light_pos, light_range);

            Lo += calculatePBR(N, V, L, H, albedo, metallic, roughness, F0, radiance) * shadow;
        }
    }

    // Image-Based Lighting (IBL) for ambient
    vec3 ambient = calculateIBL(N, V, albedo, metallic, roughness, F0, ao);

    // Final color
    vec3 color = ambient + Lo + emissive;

    // NOTE: No gamma correction here!
    // We're rendering to HDR buffer, so output linear color.
    // Gamma correction will be applied in the tonemap pass.

    // Output linear HDR color
    float alpha = texture(albedo_sampler, frag_texcoord).a * frag_color.a * push.tint_color.a;
    out_color = vec4(color, alpha);
}
