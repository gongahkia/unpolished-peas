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

struct SpriteInstanceInput {
  @location(0) points_01: vec4<f32>,
  @location(1) points_23: vec4<f32>,
  @location(2) texcoords: vec4<f32>,
  @location(3) tint: vec4<f32>,
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

@vertex
fn vs_instanced(input: SpriteInstanceInput, @builtin(vertex_index) vertex_index: u32) -> VertexOutput {
  var output: VertexOutput;
  switch vertex_index {
    case 0u, 3u: {
      output.position = vec4<f32>(input.points_01.xy, 0.0, 1.0);
      output.texcoord = input.texcoords.xy;
    }
    case 1u: {
      output.position = vec4<f32>(input.points_01.zw, 0.0, 1.0);
      output.texcoord = vec2<f32>(input.texcoords.z, input.texcoords.y);
    }
    case 2u, 4u: {
      output.position = vec4<f32>(input.points_23.xy, 0.0, 1.0);
      output.texcoord = input.texcoords.zw;
    }
    default: {
      output.position = vec4<f32>(input.points_23.zw, 0.0, 1.0);
      output.texcoord = vec2<f32>(input.texcoords.x, input.texcoords.w);
    }
  }
  output.tint = input.tint;
  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
  let sample = textureSample(sprite_texture, sprite_sampler, input.texcoord);
  let alpha = sample.a * input.tint.a;
  return vec4<f32>(sample.rgb * input.tint.rgb * alpha, alpha);
}
