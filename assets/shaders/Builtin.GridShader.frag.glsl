#version 450

layout(location = 0) in vec3 v_world_pos;
layout(location = 0) out vec4 out_color;

// Using explicit floats instead of vec3 to ensure consistent memory layout
// across Vulkan (std140) and Metal (packed) backends
layout(set = 0, binding = 1) uniform Grid {
    float camera_pos_x;
    float camera_pos_y;
    float camera_pos_z;
    float grid_height;

    float minor_spacing;   // e.g. 1.0
    float major_spacing;   // e.g. 10.0
    float fade_distance;   // e.g. 100.0
    float _pad0;           // Padding before vec4s for alignment

    vec4  minor_color;     // rgba
    vec4  major_color;     // rgba
    vec4  axis_x_color;    // X axis
    vec4  axis_z_color;    // Z axis
} grid;

float grid_mask(vec2 pos, float spacing) {
    vec2 cell = pos / spacing;
    // Distance to nearest grid line (lines at integer positions)
    // Use fract(cell + 0.5) to center lines at integer boundaries
    vec2 dist = abs(fract(cell + 0.5) - 0.5);

    float line_dist = min(dist.x, dist.y);

    // Thin, uniform line thickness
    float fw = fwidth(line_dist);
    return 1.0 - smoothstep(fw * 0.5, fw * 1.5, line_dist);
}

void main() {
    // Project onto grid plane (XZ)
    vec2 grid_pos = v_world_pos.xz;

    // Minor / major grid
    float minor = grid_mask(grid_pos, grid.minor_spacing);
    float major = grid_mask(grid_pos, grid.major_spacing);

    // Axis highlights (for XZ grid) - use same thin thickness as grid lines
    // axis_x_line: line where Z=0 (runs parallel to X-axis, red line)
    // axis_z_line: line where X=0 (runs parallel to Z-axis, blue line)
    float fw_x = fwidth(grid_pos.x);
    float fw_y = fwidth(grid_pos.y);

    float axis_x_line = 1.0 - smoothstep(fw_y * 0.5, fw_y * 1.5, abs(grid_pos.y)); // Z=0 line (X-axis direction)
    float axis_z_line = 1.0 - smoothstep(fw_x * 0.5, fw_x * 1.5, abs(grid_pos.x)); // X=0 line (Z-axis direction)

    // Base color
    vec4 color = vec4(0.0);

    color = mix(color, grid.minor_color, minor);
    color = mix(color, grid.major_color, major);

    // Apply axis colors: axis_x_color for line along X-axis, axis_z_color for line along Z-axis
    color = mix(color, grid.axis_x_color, axis_x_line);
    color = mix(color, grid.axis_z_color, axis_z_line);

    // Fade with distance
    vec3 camera_pos = vec3(grid.camera_pos_x, grid.camera_pos_y, grid.camera_pos_z);
    float dist = length(v_world_pos - camera_pos);
    float fade = clamp(1.0 - dist / grid.fade_distance, 0.0, 1.0);

    color.a *= fade;

    // Temporarily disable discard for debugging - show grid even if faded
    // if (color.a <= 0.001) {
    //     discard;
    // }

    out_color = color;
}
