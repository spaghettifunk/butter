#version 450
#extension GL_ARB_separate_shader_objects : enable

// Set 1: Skybox cubemap
layout(set = 1, binding = 0) uniform samplerCube skybox_cubemap;

// Input from vertex shader
layout(location = 0) in vec3 frag_view_ray;

// Output color
layout(location = 0) out vec4 out_color;

void main() {
    // Sample cubemap using view direction
    vec3 direction = normalize(frag_view_ray);
    vec3 color = texture(skybox_cubemap, direction).rgb;

    // Output linear HDR color (gamma correction in tonemap pass)
    out_color = vec4(color, 1.0);
}
