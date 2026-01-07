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

// PBR Material textures (Set 1)
layout(set = 1, binding = 0) uniform sampler2D albedo_sampler;
layout(set = 1, binding = 1) uniform sampler2D metallic_roughness_sampler; // G=roughness, B=metallic
layout(set = 1, binding = 2) uniform sampler2D normal_sampler;
layout(set = 1, binding = 3) uniform sampler2D ao_sampler;
layout(set = 1, binding = 4) uniform sampler2D emissive_sampler;
layout(set = 1, binding = 5) uniform samplerCube irradiance_map;        // Diffuse IBL (placeholder for Phase 2)
layout(set = 1, binding = 6) uniform samplerCube prefiltered_map;       // Specular IBL (placeholder for Phase 2)
layout(set = 1, binding = 7) uniform sampler2D brdf_lut;                // BRDF LUT (placeholder for Phase 2)

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

void main() {
    // Sample PBR textures
    vec3 albedo = texture(albedo_sampler, frag_texcoord).rgb;
    albedo = pow(albedo, vec3(2.2)); // sRGB to linear
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

    // Directional light
    if (ubo.dir_light_enabled > 0.5) {
        vec3 L = normalize(-ubo.dir_light_direction);
        vec3 H = normalize(V + L);
        vec3 radiance = ubo.dir_light_color * ubo.dir_light_intensity;

        Lo += calculatePBR(N, V, L, H, albedo, metallic, roughness, F0, radiance);
    }

    // Point lights
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

            Lo += calculatePBR(N, V, L, H, albedo, metallic, roughness, F0, radiance);
        }
    }

    // Ambient lighting (simple for now, will be replaced with IBL in Phase 2)
    vec3 ambient = ubo.ambient_color.rgb * ubo.ambient_color.a * albedo * ao;

    // Final color
    vec3 color = ambient + Lo + emissive;

    // Gamma correction (linear to sRGB)
    color = pow(color, vec3(1.0 / 2.2));

    // Output
    float alpha = texture(albedo_sampler, frag_texcoord).a * frag_color.a * push.tint_color.a;
    out_color = vec4(color, alpha);
}
