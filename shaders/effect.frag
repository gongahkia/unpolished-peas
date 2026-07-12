#version 450
layout(set = 2, binding = 0) uniform sampler2D source_texture;
layout(set = 3, binding = 0) uniform Parameters { float amount; } params;
layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;
void main() {
    vec4 color = texture(source_texture, in_uv);
    out_color = vec4(mix(color.rgb, vec3(1.0) - color.rgb, params.amount), color.a);
}
