// 72 shader: sprite-2d v1
// Inputs and texture samples are straight alpha. fs_main returns premultiplied
// output for the blend state selected by the private pipeline cache.

struct VertexInput {
  @location(0) position: vec2<f32>,
  @location(1) texcoord: vec2<f32>,
  @location(2) tint: vec4<f32>,
}

struct VertexOutput {
  @builtin(position) position: vec4<f32>,
  @location(0) texcoord: vec2<f32>,
  @location(1) tint: vec4<f32>,
}

@group(0) @binding(0) var sprite_texture: texture_2d<f32>;
@group(0) @binding(1) var sprite_sampler: sampler;

@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
  var output: VertexOutput;
  output.position = vec4<f32>(input.position, 0.0, 1.0);
  output.texcoord = input.texcoord;
  output.tint = input.tint;
  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
  let sample = textureSample(sprite_texture, sprite_sampler, input.texcoord);
  let alpha = sample.a * input.tint.a;
  return vec4<f32>(sample.rgb * input.tint.rgb * alpha, alpha);
}
