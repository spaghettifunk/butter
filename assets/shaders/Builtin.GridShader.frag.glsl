#version 450

layout(location = 0) in vec3 v_world_pos;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 1) uniform Grid {
    vec3  camera_pos;
    float grid_height;

    float minor_spacing;   // e.g. 1.0
    float major_spacing;   // e.g. 10.0

    float fade_distance;   // e.g. 100.0

    vec4  minor_color;     // rgba
    vec4  major_color;     // rgba
    vec4  axis_x_color;    // X axis
    vec4  axis_z_color;    // Z axis
} grid;

float grid_mask(vec2 pos, float spacing) {
    vec2 cell = pos / spacing;
    vec2 dist = abs(fract(cell - 0.5) - 0.5);

    float line_dist = min(dist.x, dist.y);

    // screen-space anti-aliasing
    float fw = fwidth(line_dist);
    return 1.0 - smoothstep(0.0, fw, line_dist);
}

void main() {
    // Project onto grid plane (XZ)
    vec2 grid_pos = v_world_pos.xz;

    // Minor / major grid
    float minor = grid_mask(grid_pos, grid.minor_spacing);
    float major = grid_mask(grid_pos, grid.major_spacing);

    // Axis highlights
    float fw_x = fwidth(grid_pos.x);
    float fw_z = fwidth(grid_pos.y);

    float axis_x = 1.0 - smoothstep(0.0, fw_x, abs(grid_pos.x));
    float axis_z = 1.0 - smoothstep(0.0, fw_z, abs(grid_pos.y));

    // Base color
    vec4 color = vec4(0.0);

    color = mix(color, grid.minor_color, minor);
    color = mix(color, grid.major_color, major);

    color = mix(color, grid.axis_x_color, axis_x);
    color = mix(color, grid.axis_z_color, axis_z);

    // Fade with distance
    float dist = length(v_world_pos - grid.camera_pos);
    float fade = clamp(1.0 - dist / grid.fade_distance, 0.0, 1.0);

    color.a *= fade;

    // Optional: discard fully transparent pixels
    if (color.a <= 0.001) {
        discard;
    }

    out_color = color;
}
