#version 450
layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_tint;
layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_tint;
void main() {
    gl_Position = vec4(in_position, 0.0, 1.0);
    out_uv = in_uv;
    out_tint = in_tint;
}
