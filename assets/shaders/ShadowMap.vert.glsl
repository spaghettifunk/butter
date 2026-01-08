#version 450

// Vertex attributes
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_texcoord;
layout(location = 3) in vec3 in_tangent;

// Push constants for model matrix and cascade index
layout(push_constant) uniform PushConstants {
    mat4 model;           // Model matrix (64 bytes)
    vec4 material_params; // roughness, metallic, emissive_strength, unused (16 bytes)
    uint cascade_index;   // Which cascade to render to (4 bytes)
} push;

// Set 0, Binding 1: Shadow UBO
layout(set = 0, binding = 1) uniform ShadowUBO {
    mat4 cascade_view_proj[4];    // Light-space matrices for each cascade
    vec4 cascade_splits;           // Split distances
    vec4 shadow_params;            // bias, slope_bias, pcf_samples, enabled
    vec4 point_shadow_enabled;     // Point light shadow flags
    vec4 point_shadow_indices;     // Point light shadow indices
} shadow_ubo;

void main() {
    // Transform vertex to world space
    vec4 world_pos = push.model * vec4(in_position, 1.0);

    // Transform to light space using the appropriate cascade matrix
    gl_Position = shadow_ubo.cascade_view_proj[push.cascade_index] * world_pos;
}
