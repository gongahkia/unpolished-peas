#version 450

layout(location = 0) in vec2 in_corner;
layout(location = 1) in vec2 in_center;
layout(location = 2) in vec2 in_extent;
layout(location = 3) in vec4 in_color;

layout(location = 0) out vec4 out_color;

void main() {
    gl_Position = vec4(in_center + in_corner * in_extent, 0.0, 1.0);
    out_color = in_color;
}
