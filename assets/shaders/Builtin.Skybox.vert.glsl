#version 450
#extension GL_ARB_separate_shader_objects : enable

// Set 0: Global UBO (camera matrices)
layout(set = 0, binding = 0) uniform GlobalUBO {
    mat4 projection;
    mat4 view;
    vec3 camera_position;
    float _pad0;
    // ... (rest of UBO, we only need projection and view)
} ubo;

// Output to fragment shader
layout(location = 0) out vec3 frag_view_ray;

void main() {
    // Fullscreen triangle using vertex index
    // Vertices: (-1,-1), (3,-1), (-1,3)
    // Covers entire screen with single triangle
    vec2 positions[3] = vec2[](
        vec2(-1.0, -1.0),
        vec2( 3.0, -1.0),
        vec2(-1.0,  3.0)
    );

    vec2 position = positions[gl_VertexIndex];

    // Output at far plane (depth = 1.0)
    gl_Position = vec4(position, 1.0, 1.0);

    // Calculate view ray for cubemap sampling
    // Remove translation from view matrix (keep only rotation)
    mat4 view_no_translation = mat4(mat3(ubo.view));

    // Inverse projection to get view-space ray
    mat4 inv_projection = inverse(ubo.projection);
    vec4 view_ray_clip = vec4(position, 1.0, 1.0);
    vec4 view_ray_view = inv_projection * view_ray_clip;
    view_ray_view = view_ray_view / view_ray_view.w; // Perspective divide

    // Transform to world space (without translation)
    vec4 view_ray_world = inverse(view_no_translation) * view_ray_view;

    // Output view ray (will be interpolated across triangle)
    frag_view_ray = view_ray_world.xyz;
}
