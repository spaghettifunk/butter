#version 450

layout(location = 0) in vec3 in_position;   // world-space quad vertex

layout(set = 0, binding = 0) uniform Camera {
    mat4 view_proj;
} camera;

layout(location = 0) out vec3 v_world_pos;

void main() {
    v_world_pos = in_position;
    gl_Position = camera.view_proj * vec4(in_position, 1.0);
}
