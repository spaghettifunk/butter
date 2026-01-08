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

// Push constants for per-object data (model matrix + material parameters)
// More efficient than UBO for frequently changing per-draw data
// Total: 128 bytes
layout(push_constant) uniform PushConstants {
    mat4 model;              // 64 bytes - model transformation matrix
    vec4 tint_color;         // 16 bytes - material tint color
    vec4 material_params;    // 16 bytes - roughness, metallic, emission, pad
    vec2 uv_offset;          // 8 bytes - UV offset
    vec2 uv_scale;           // 8 bytes - UV scale
    uint flags;              // 4 bytes - material flags
    // padding: 12 bytes
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
layout(location = 4) out vec3 frag_tangent;
layout(location = 5) out vec3 frag_bitangent;

void main() {
    vec4 world_pos = push.model * vec4(in_position, 1.0);
    gl_Position = ubo.projection * ubo.view * world_pos;

    frag_pos = vec3(world_pos);

    // Transform normal to world space (using mat3 of model matrix since we assume uniform scaling)
    // For non-uniform scaling, we should use inverse(transpose(mat3(model)))
    mat3 model_mat3 = mat3(push.model);
    vec3 N = normalize(model_mat3 * in_normal);
    frag_normal = N;

    // Transform tangent to world space and calculate bitangent for normal mapping
    vec3 T = normalize(model_mat3 * in_tangent.xyz);
    // Re-orthogonalize T with respect to N (Gram-Schmidt process)
    T = normalize(T - dot(T, N) * N);
    // Calculate bitangent using cross product (handedness stored in tangent.w)
    vec3 B = cross(N, T) * in_tangent.w;

    frag_tangent = T;
    frag_bitangent = B;

    frag_color = in_color;

    // Apply UV transform (scale and offset) from push constants
    frag_texcoord = in_texcoord * push.uv_scale + push.uv_offset;
}
