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

layout(set = 1, binding = 0) uniform sampler2D diffuse_sampler;
layout(set = 1, binding = 1) uniform sampler2D specular_sampler;

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

layout(location = 0) out vec4 out_color;

// Calculate lighting from point light
vec3 calculatePointLight(vec3 position, float range, vec3 color, float intensity,
                         vec3 normal, vec3 frag_pos, vec3 view_dir,
                         vec3 specular_color, float shininess) {
    vec3 light_dir = position - frag_pos;
    float distance = length(light_dir);
    light_dir = normalize(light_dir);

    // Attenuation (inverse square with range limit)
    float attenuation = 1.0 / (1.0 + distance * distance);
    attenuation *= smoothstep(range, range * 0.5, distance);

    // Diffuse
    float diff = max(dot(normal, light_dir), 0.0);
    vec3 diffuse = diff * color * intensity * attenuation;

    // Specular (Blinn-Phong)
    vec3 halfway_dir = normalize(light_dir + view_dir);
    float spec = pow(max(dot(normal, halfway_dir), 0.0), shininess);
    vec3 specular = specular_color * spec * intensity * attenuation;

    return diffuse + specular;
}

// Calculate lighting from directional light
vec3 calculateDirectionalLight(vec3 direction, vec3 color, float intensity,
                                vec3 normal, vec3 view_dir,
                                vec3 specular_color, float shininess) {
    vec3 light_dir = normalize(-direction);

    // Diffuse
    float diff = max(dot(normal, light_dir), 0.0);
    vec3 diffuse = diff * color * intensity;

    // Specular (Blinn-Phong)
    vec3 halfway_dir = normalize(light_dir + view_dir);
    float spec = pow(max(dot(normal, halfway_dir), 0.0), shininess);
    vec3 specular = specular_color * spec * intensity;

    return diffuse + specular;
}

void main() {
    vec4 diffuse_tex = texture(diffuse_sampler, frag_texcoord);
    vec4 specular_tex = texture(specular_sampler, frag_texcoord);

    // Apply material tint color from push constants
    diffuse_tex.rgb *= push.tint_color.rgb;

    // Extract material parameters
    float roughness = push.material_params.x;
    float metallic = push.material_params.y;
    float emission = push.material_params.z;

    vec3 specular_color = specular_tex.rgb;
    float shininess = specular_tex.a * 128.0; // Map 0-1 to 0-128
    if (shininess < 1.0) shininess = 32.0; // Default if no specular map

    // Apply roughness to shininess (rougher = less shiny)
    shininess *= (1.0 - roughness);

    vec3 normal = normalize(frag_normal);
    vec3 view_dir = normalize(ubo.camera_position - frag_pos);

    // Ambient
    vec3 ambient = ubo.ambient_color.rgb * ubo.ambient_color.a;

    // Accumulate lighting
    vec3 lighting = vec3(0.0);

    // Directional light
    if (ubo.dir_light_enabled > 0.5) {
        lighting += calculateDirectionalLight(
            ubo.dir_light_direction,
            ubo.dir_light_color,
            ubo.dir_light_intensity,
            normal, view_dir,
            specular_color, shininess
        );
    }

    // Point lights
    for (uint i = 0u; i < ubo.point_light_count && i < 8u; i++) {
        uint idx = i * 2u;
        vec3 position = ubo.point_lights[idx].xyz;
        float range = ubo.point_lights[idx].w;
        vec3 color = ubo.point_lights[idx + 1u].xyz;
        float intensity = ubo.point_lights[idx + 1u].w;

        if (intensity > 0.0) {
            lighting += calculatePointLight(
                position, range, color, intensity,
                normal, frag_pos, view_dir,
                specular_color, shininess
            );
        }
    }

    // Final color with emission
    vec3 result = (ambient + lighting) * diffuse_tex.rgb * frag_color.rgb;
    result += diffuse_tex.rgb * emission; // Add emission
    out_color = vec4(result, diffuse_tex.a * frag_color.a * push.tint_color.a);
}
