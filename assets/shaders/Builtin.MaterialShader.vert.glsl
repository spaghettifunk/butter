#version 450
#extension GL_ARB_separate_shader_objects : enable

layout(set = 0, binding = 0) uniform GlobalUBO {
    // Matrices (128 bytes) - projection and view only, model moved to push constants
    mat4 projection;
    mat4 view;

    // Shadow mapping matrices (128 bytes)
    mat4 light_space_matrix;
    mat4 shadow_projection;

    // Camera data (16 bytes, padded to vec4)
    vec3 camera_position;
    float _pad0;

    // Light data (32 bytes)
    vec3 light_direction;
    float light_intensity;
    vec3 light_color;
    float shadow_map_size;

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

// Push constants for per-object data (model matrix)
// More efficient than UBO for frequently changing per-draw data
layout(push_constant) uniform PushConstants {
    mat4 model;
} push;

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_color;
layout(location = 2) in vec2 in_texcoord;

layout(location = 0) out vec3 frag_color;
layout(location = 1) out vec2 frag_texcoord;

void main() {
    gl_Position = ubo.projection * ubo.view * push.model * vec4(in_position, 1.0);
    frag_color = in_color;
    frag_texcoord = in_texcoord;
}
