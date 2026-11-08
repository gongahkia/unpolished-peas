#version 450
layout(set = 2, binding = 0) uniform sampler2D sprite_texture;
layout(set = 3, binding = 0, std140) uniform SurfaceParameters {
    ivec4 destination;
    uvec4 sampling;
};
layout(origin_upper_left) in vec4 gl_FragCoord;
layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_tint;
layout(location = 0) out vec4 out_color;
void main() {
    vec4 sample_color;
    if (sampling.x == 0u) {
        ivec2 relative = ivec2(gl_FragCoord.xy) - destination.xy;
        ivec2 size = textureSize(sprite_texture, 0);
        ivec2 coordinate = relative * size / destination.zw;
        sample_color = texelFetch(sprite_texture, clamp(coordinate, ivec2(0), size - 1), 0);
    } else {
        sample_color = texture(sprite_texture, in_uv);
    }
    // Match Canvas's byte tint multiplication before hardware alpha blending.
    uvec4 source = uvec4(floor(clamp(sample_color, 0.0, 1.0) * 255.0 + 0.5));
    uvec4 tint = uvec4(floor(clamp(in_tint, 0.0, 1.0) * 255.0 + 0.5));
    out_color = vec4(source * tint / 255u) / 255.0;
}
