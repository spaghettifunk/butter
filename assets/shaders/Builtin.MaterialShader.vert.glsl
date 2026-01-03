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

    // Point light 0 (32 bytes)
    vec3 point_light_0_position;
    float point_light_0_range;
    vec3 point_light_0_color;
    float point_light_0_intensity;

    // Point light 1 (32 bytes)
    vec3 point_light_1_position;
    float point_light_1_range;
    vec3 point_light_1_color;
    float point_light_1_intensity;

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
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_texcoord;
layout(location = 3) in vec4 in_tangent;
layout(location = 4) in vec4 in_color;

layout(location = 0) out vec4 frag_color;
layout(location = 1) out vec2 frag_texcoord;
layout(location = 2) out vec3 frag_normal;
layout(location = 3) out vec3 frag_pos;

void main() {
    vec4 world_pos = push.model * vec4(in_position, 1.0);
    gl_Position = ubo.projection * ubo.view * world_pos;
    
    frag_pos = vec3(world_pos);
    
    // Transform normal to world space (using mat3 of model matrix since we assume uniform scaling)
    // For non-uniform scaling, we should use inverse(transpose(mat3(model)))
    frag_normal = normalize(mat3(push.model) * in_normal);
    
    frag_color = in_color;
    frag_texcoord = in_texcoord;
}
