#version 450
#extension GL_ARB_separate_shader_objects : enable

layout(set = 0, binding = 0) uniform GlobalUBO {
    // Matrices (128 bytes)
    mat4 projection;
    mat4 view;

    // Shadow mapping matrices (128 bytes)
    mat4 light_space_matrix;
    mat4 shadow_projection;

    // Camera data (16 bytes)
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

layout(set = 0, binding = 1) uniform sampler2D tex_sampler;

layout(location = 0) in vec4 frag_color;
layout(location = 1) in vec2 frag_texcoord;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_pos;

layout(location = 0) out vec4 out_color;

void main() {
    vec4 tex_color = texture(tex_sampler, frag_texcoord);
    
    // Ambient component
    vec3 ambient = ubo.ambient_color.rgb * ubo.ambient_color.a;
    
    // Diffuse component
    vec3 norm = normalize(frag_normal);
    // Light direction is direction of rays, so we need vector pointing TO light source
    vec3 light_dir = normalize(-ubo.light_direction);
    float diff = max(dot(norm, light_dir), 0.0);
    vec3 diffuse = diff * ubo.light_color * ubo.light_intensity;
    
    // Specular component (Blinn-Phong)
    vec3 view_dir = normalize(ubo.camera_position - frag_pos);
    vec3 halfway_dir = normalize(light_dir + view_dir);
    float spec = pow(max(dot(norm, halfway_dir), 0.0), 32.0); // Hardcoded shininess for now
    vec3 specular = vec3(0.5) * spec * ubo.light_intensity; // Hardcoded specular color
    
    // Combine results
    vec3 result = (ambient + diffuse + specular) * tex_color.rgb * frag_color.rgb;
    
    out_color = vec4(result, tex_color.a * frag_color.a);
}
