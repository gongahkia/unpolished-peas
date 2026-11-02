async (page) => {
  const results = await page.evaluate(async () => {
    const {createBrowserHost} = await import("./host.mjs");
    const vertexGl = `#version 300 es
      layout(location=0) in vec2 position;
      layout(location=1) in vec2 uv;
      layout(location=2) in vec4 tint;
      out vec2 out_uv;
      void main() { gl_Position=vec4(position,0,1); out_uv=uv; }`;
    const fragmentGl = `#version 300 es
      precision highp float;
      uniform sampler2D source;
      layout(std140) uniform Paint { vec4 paint; };
      in vec2 out_uv;
      out vec4 color;
      void main() { color=texture(source,out_uv)*paint; }`;
    const postGl = `#version 300 es
      precision highp float;
      uniform sampler2D source;
      in vec2 out_uv;
      out vec4 color;
      void main() { color=texture(source,out_uv); }`;
    const vertexWgsl = `struct Output { @builtin(position) position: vec4f, @location(0) uv: vec2f }
      @vertex fn main(@location(0) position: vec2f, @location(1) uv: vec2f, @location(2) tint: vec4f) -> Output {
        return Output(vec4f(position,0,1),uv);
      }`;
    const fragmentWgsl = `@group(0) @binding(0) var source: texture_2d<f32>;
      @group(0) @binding(1) var source_sampler: sampler;
      @group(0) @binding(2) var<uniform> paint: vec4f;
      @fragment fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        return textureSample(source,source_sampler,uv)*paint;
      }`;
    const postWgsl = `@group(0) @binding(0) var source: texture_2d<f32>;
      @group(0) @binding(1) var source_sampler: sampler;
      @fragment fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        return textureSample(source,source_sampler,uv);
      }`;
    const captures = [];
    for (const renderer of ["webgl2", "webgpu"]) {
      const canvas = document.createElement("canvas");
      const host = createBrowserHost({canvas});
      try {
        if (renderer === "webgpu") await host.initializeWebGpu(16, 16);
        const env = host.imports.env;
        const call = (name, ...args) => {
          const status = env[name](...args);
          if (status !== 0) throw new Error(`${renderer}: ${name} returned ${status}`);
        };
        let offset = 1024;
        const text = (value) => {
          const bytes = new TextEncoder().encode(value);
          const address = offset;
          new Uint8Array(host.memory.buffer, address, bytes.length).set(bytes);
          offset += bytes.length;
          return [address, bytes.length];
        };
        const vertex = text(vertexGl), fragment = text(fragmentGl), post = text(postGl);
        const wVertex = text(vertexWgsl), wFragment = text(fragmentWgsl), wPost = text(postWgsl);
        const source = text("source"), paint = text("Paint");
        new Uint8Array(host.memory.buffer, 16000, 4).fill(255);
        call("up_host_gl_context_create", 16, 16);
        // Reuse the same material twice with different geometry and uniforms.
        // Check odd and even post counts to expose accidental vertical flips.
        for (const passes of [0, 1, 2]) {
          call("up_host_gl_clear", 0xff000000);
          for (const [x, y, rgba] of [[1, 1, [1, 0, 0, 1]], [10, 8, [0, 1, 0, 1]]]) {
            new Float32Array(host.memory.buffer, 16100, 4).set(rgba);
            call("up_host_gl_material_begin", 42, 1, 0, ...vertex, ...fragment, ...wVertex, ...wFragment);
            call("up_host_gl_material_bind_texture", ...source, 1, 1, 16000, 4);
            call("up_host_gl_material_bind_uniform", ...paint, 16100, 16);
            call("up_host_gl_material_draw", x, y, 3, 3, 0xffffffff);
          }
          for (let index = 0; index < passes; index += 1) {
            call("up_host_gl_material_begin", 43, 1, 1, ...vertex, ...post, ...wVertex, ...wPost);
            call("up_host_gl_material_draw", 0, 0, 16, 16, 0xffffffff);
          }
          call("up_host_gl_present", 0);
          const image = new Image();
          image.src = host.captureFrame();
          await image.decode();
          const target = document.createElement("canvas");
          target.width = target.height = 16;
          const context = target.getContext("2d");
          context.drawImage(image, 0, 0);
          const pixels = context.getImageData(0, 0, 16, 16).data;
          for (let y = 0; y < 16; y += 1) for (let x = 0; x < 16; x += 1) {
            const expected = x >= 1 && x < 4 && y >= 1 && y < 4 ? [255, 0, 0, 255]
              : x >= 10 && x < 13 && y >= 8 && y < 11 ? [0, 255, 0, 255] : [0, 0, 0, 255];
            if (!expected.every((value, channel) => Math.abs(pixels[(y * 16 + x) * 4 + channel] - value) <= 1)) {
              throw new Error(`${renderer}: material capture mismatch at ${x},${y} after ${passes} post passes`);
            }
          }
          captures.push(`${renderer}:${passes}`);
        }
      } finally {
        host.imports.env.up_host_teardown();
      }
    }
    return captures;
  });
  if (results.length !== 6) throw new Error("missing material captures");
  return "peas-material-checks-passed";
}
