export class WebGpuBackendError extends Error {
  constructor(code) {
    super(`unpolished-peas WebGPU: ${code}`);
    this.code = code;
  }
}

function colorFromPacked(value) {
  const color = value >>> 0;
  return {r: (color & 0xff) / 255, g: ((color >>> 8) & 0xff) / 255, b: ((color >>> 16) & 0xff) / 255, a: ((color >>> 24) & 0xff) / 255};
}

function validDimensions(width, height) {
  return Number.isInteger(width) && Number.isInteger(height) && width > 0 && height > 0;
}

const maxRectangles = 4096;
const maxSprites = 4096;
const maxBatches = maxRectangles + maxSprites;
const floatsPerVertex = 6;
const verticesPerRectangle = 6;
const spriteFloatsPerVertex = 8;
const vertexShader = `
struct Output { @builtin(position) position: vec4f, @location(0) color: vec4f }
@vertex fn main(@location(0) position: vec2f, @location(1) color: vec4f) -> Output { return Output(vec4f(position, 0.0, 1.0), color); }
@fragment fn fragment(input: Output) -> @location(0) vec4f { return input.color; }
`;
const spriteShader = `
struct Output { @builtin(position) position: vec4f, @location(0) uv: vec2f, @location(1) color: vec4f }
@group(0) @binding(0) var image: texture_2d<f32>;
@group(0) @binding(1) var image_sampler: sampler;
@vertex fn main(@location(0) position: vec2f, @location(1) uv: vec2f, @location(2) color: vec4f) -> Output { return Output(vec4f(position, 0.0, 1.0), uv, color); }
@fragment fn fragment(input: Output) -> @location(0) vec4f { return textureSample(image, image_sampler, input.uv) * input.color; }
`;
const alphaBlend = {color: {srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add"}, alpha: {srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add"}};
const additiveBlend = {color: {srcFactor: "src-alpha", dstFactor: "one", operation: "add"}, alpha: {srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add"}};

function intersect(a, b) {
  const x = Math.max(a.x, b.x);
  const y = Math.max(a.y, b.y);
  return {x, y, width: Math.max(0, Math.min(a.x + a.width, b.x + b.width) - x), height: Math.max(0, Math.min(a.y + a.height, b.y + b.height) - y)};
}

export async function createWebGpuBackend({canvas, navigator: navigatorRef = globalThis.navigator, onDeviceLost} = {}) {
  if (!canvas?.getContext) throw new WebGpuBackendError("canvas_unavailable");
  const gpu = navigatorRef?.gpu;
  if (!gpu?.requestAdapter || !gpu?.getPreferredCanvasFormat) throw new WebGpuBackendError("webgpu_unavailable");
  const context = canvas.getContext("webgpu");
  if (!context?.configure || !context?.getCurrentTexture) throw new WebGpuBackendError("canvas_context_unavailable");
  let adapter;
  try {
    adapter = await gpu.requestAdapter();
  } catch {
    throw new WebGpuBackendError("adapter_request_failed");
  }
  if (!adapter?.requestDevice) throw new WebGpuBackendError("adapter_unavailable");
  let device;
  try {
    device = await adapter.requestDevice();
  } catch {
    throw new WebGpuBackendError("device_request_failed");
  }
  if (!device?.queue?.submit || !device.queue.writeBuffer || !device.queue.writeTexture || !device.createCommandEncoder || !device.createShaderModule || !device.createRenderPipeline || !device.createBuffer || !device.createTexture || !device.createSampler || !device.createBindGroup || !device.createBindGroupLayout || !device.createPipelineLayout) throw new WebGpuBackendError("device_unavailable");
  const format = gpu.getPreferredCanvasFormat();
  if (typeof format !== "string" || format.length === 0) throw new WebGpuBackendError("canvas_format_unavailable");
  const shader = device.createShaderModule({code: vertexShader});
  const pipelines = [alphaBlend, additiveBlend].map((blend) => device.createRenderPipeline({
    layout: "auto",
    vertex: {module: shader, buffers: [{arrayStride: floatsPerVertex * 4, attributes: [{shaderLocation: 0, offset: 0, format: "float32x2"}, {shaderLocation: 1, offset: 8, format: "float32x4"}]}]},
    fragment: {module: shader, targets: [{format, blend}]},
    primitive: {topology: "triangle-list"},
  }));
  const spriteModule = device.createShaderModule({code: spriteShader});
  const spriteBindGroupLayout = device.createBindGroupLayout({entries: [{binding: 0, visibility: globalThis.GPUShaderStage?.FRAGMENT ?? 0x2, texture: {}}, {binding: 1, visibility: globalThis.GPUShaderStage?.FRAGMENT ?? 0x2, sampler: {}}]});
  const spritePipelineLayout = device.createPipelineLayout({bindGroupLayouts: [spriteBindGroupLayout]});
  const spritePipelines = [alphaBlend, additiveBlend].map((blend) => device.createRenderPipeline({
    layout: spritePipelineLayout,
    vertex: {module: spriteModule, buffers: [{arrayStride: spriteFloatsPerVertex * 4, attributes: [{shaderLocation: 0, offset: 0, format: "float32x2"}, {shaderLocation: 1, offset: 8, format: "float32x2"}, {shaderLocation: 2, offset: 16, format: "float32x4"}]}]},
    fragment: {module: spriteModule, targets: [{format, blend}]},
    primitive: {topology: "triangle-list"},
  }));
  const usage = globalThis.GPUBufferUsage?.VERTEX | globalThis.GPUBufferUsage?.COPY_DST || 0x28;
  const vertexBuffer = device.createBuffer({size: maxRectangles * verticesPerRectangle * floatsPerVertex * 4, usage});
  const spriteBuffer = device.createBuffer({size: maxSprites * verticesPerRectangle * spriteFloatsPerVertex * 4, usage});
  const batches = Array.from({length: maxBatches}, () => ({kind: "", offset: 0, count: 0, texture: null, blend: 0}));
  const state = {adapterStatus: "ready", deviceStatus: "ready", destroyed: false, width: 0, height: 0, clear: colorFromPacked(0xff000000), clip: null, clips: [], blend: 0, blends: [], vertices: new Float32Array(maxRectangles * verticesPerRectangle * floatsPerVertex), vertexCount: 0, spriteVertices: new Float32Array(maxSprites * verticesPerRectangle * spriteFloatsPerVertex), spriteVertexCount: 0, batchCount: 0, textures: new Map()};
  const reportLoss = (info) => {
    if (state.destroyed) return;
    state.deviceStatus = "lost";
    onDeviceLost?.({reason: typeof info?.reason === "string" ? info.reason : "unknown"});
  };
  Promise.resolve(device.lost).then(reportLoss, () => reportLoss());

  function resize(width, height) {
    if (state.destroyed || state.deviceStatus !== "ready" || !validDimensions(width, height)) return false;
    canvas.width = width;
    canvas.height = height;
    try {
      context.configure({device, format, alphaMode: "premultiplied"});
    } catch {
      state.deviceStatus = "configuration_failed";
      return false;
    }
    state.width = width;
    state.height = height;
    return true;
  }

  function clear(color) {
    if (state.destroyed || state.deviceStatus !== "ready" || !Number.isInteger(color)) return false;
    state.clear = colorFromPacked(color);
    state.vertexCount = 0;
    state.spriteVertexCount = 0;
    state.batchCount = 0;
    return true;
  }

  function appendBatch(kind, offset, texture = null) {
    const previous = state.batchCount === 0 ? null : batches[state.batchCount - 1];
    if (previous?.kind === kind && previous.texture === texture && previous.blend === state.blend) return previous;
    if (state.batchCount === maxBatches) return null;
    const batch = batches[state.batchCount];
    state.batchCount += 1;
    batch.kind = kind;
    batch.offset = offset;
    batch.count = 0;
    batch.texture = texture;
    batch.blend = state.blend;
    return batch;
  }

  function drawRect(x, y, width, height, color) {
    if (state.destroyed || state.deviceStatus !== "ready" || ![x, y, width, height, color].every(Number.isInteger)) return false;
    const rect = state.clip ? intersect({x, y, width, height}, state.clip) : {x, y, width, height};
    if (rect.width <= 0 || rect.height <= 0) return true;
    if (state.vertexCount + verticesPerRectangle > maxRectangles * verticesPerRectangle) return false;
    const batch = appendBatch("primitive", state.vertexCount);
    if (!batch) return false;
    const rgba = colorFromPacked(color);
    const x0 = rect.x * 2 / state.width - 1;
    const x1 = (rect.x + rect.width) * 2 / state.width - 1;
    const y0 = 1 - rect.y * 2 / state.height;
    const y1 = 1 - (rect.y + rect.height) * 2 / state.height;
    const points = [x0, y0, x1, y0, x1, y1, x0, y0, x1, y1, x0, y1];
    let offset = state.vertexCount * floatsPerVertex;
    for (let index = 0; index < points.length; index += 2) {
      state.vertices[offset] = points[index];
      state.vertices[offset + 1] = points[index + 1];
      state.vertices[offset + 2] = rgba.r;
      state.vertices[offset + 3] = rgba.g;
      state.vertices[offset + 4] = rgba.b;
      state.vertices[offset + 5] = rgba.a;
      offset += floatsPerVertex;
    }
    state.vertexCount += verticesPerRectangle;
    batch.count += verticesPerRectangle;
    return true;
  }

  function uploadTexture(handle, width, height, pixels, sampling) {
    if (state.destroyed || state.deviceStatus !== "ready" || !Number.isInteger(handle) || handle <= 0 || !validDimensions(width, height) || !(pixels instanceof Uint8Array) || pixels.byteLength !== width * height * 4 || (sampling !== 0 && sampling !== 1) || state.textures.has(handle)) return false;
    const textureUsage = globalThis.GPUTextureUsage?.TEXTURE_BINDING | globalThis.GPUTextureUsage?.COPY_DST || 0x0c;
    let texture = null;
    try {
      texture = device.createTexture({size: {width, height, depthOrArrayLayers: 1}, format: "rgba8unorm", usage: textureUsage});
      device.queue.writeTexture({texture}, pixels, {bytesPerRow: width * 4, rowsPerImage: height}, {width, height, depthOrArrayLayers: 1});
      const sampler = device.createSampler({magFilter: sampling === 0 ? "nearest" : "linear", minFilter: sampling === 0 ? "nearest" : "linear"});
      const bindGroup = device.createBindGroup({layout: spriteBindGroupLayout, entries: [{binding: 0, resource: texture.createView()}, {binding: 1, resource: sampler}]});
      state.textures.set(handle, {texture, bindGroup, width, height, sampling});
      return true;
    } catch {
      texture?.destroy?.();
      return false;
    }
  }

  function destroyTexture(handle) {
    const texture = state.textures.get(handle);
    if (!texture) return false;
    texture.texture.destroy?.();
    state.textures.delete(handle);
    return true;
  }

  function drawSprite(handle, sourceX, sourceY, sourceWidth, sourceHeight, x, y, width, height, color, sampling) {
    const texture = state.textures.get(handle);
    if (state.destroyed || state.deviceStatus !== "ready" || !texture || ![sourceX, sourceY, sourceWidth, sourceHeight, x, y, width, height, color, sampling].every(Number.isInteger) || sourceWidth <= 0 || sourceHeight <= 0 || width <= 0 || height <= 0 || sourceX < 0 || sourceY < 0 || sourceX > texture.width - sourceWidth || sourceY > texture.height - sourceHeight || sampling !== texture.sampling || state.spriteVertexCount + verticesPerRectangle > maxSprites * verticesPerRectangle) return false;
    const rect = state.clip ? intersect({x, y, width, height}, state.clip) : {x, y, width, height};
    if (rect.width <= 0 || rect.height <= 0) return true;
    const batch = appendBatch("sprite", state.spriteVertexCount, texture);
    if (!batch) return false;
    const x0 = rect.x * 2 / state.width - 1;
    const x1 = (rect.x + rect.width) * 2 / state.width - 1;
    const y0 = 1 - rect.y * 2 / state.height;
    const y1 = 1 - (rect.y + rect.height) * 2 / state.height;
    const u0 = (sourceX + (rect.x - x) * sourceWidth / width) / texture.width;
    const v0 = (sourceY + (rect.y - y) * sourceHeight / height) / texture.height;
    const u1 = (sourceX + (rect.x + rect.width - x) * sourceWidth / width) / texture.width;
    const v1 = (sourceY + (rect.y + rect.height - y) * sourceHeight / height) / texture.height;
    const rgba = colorFromPacked(color);
    const values = [x0, y0, u0, v0, x1, y0, u1, v0, x1, y1, u1, v1, x0, y0, u0, v0, x1, y1, u1, v1, x0, y1, u0, v1];
    let offset = state.spriteVertexCount * spriteFloatsPerVertex;
    for (let index = 0; index < values.length; index += 4) {
      state.spriteVertices[offset] = values[index];
      state.spriteVertices[offset + 1] = values[index + 1];
      state.spriteVertices[offset + 2] = values[index + 2];
      state.spriteVertices[offset + 3] = values[index + 3];
      state.spriteVertices[offset + 4] = rgba.r;
      state.spriteVertices[offset + 5] = rgba.g;
      state.spriteVertices[offset + 6] = rgba.b;
      state.spriteVertices[offset + 7] = rgba.a;
      offset += spriteFloatsPerVertex;
    }
    state.spriteVertexCount += verticesPerRectangle;
    batch.count += verticesPerRectangle;
    return true;
  }

  function pushClip(x, y, width, height) {
    if (state.destroyed || ![x, y, width, height].every(Number.isInteger) || width < 0 || height < 0) return false;
    state.clips.push(state.clip);
    state.clip = state.clip ? intersect(state.clip, {x, y, width, height}) : {x, y, width, height};
    return true;
  }

  function popClip() {
    if (state.destroyed || state.clips.length === 0) return false;
    state.clip = state.clips.pop();
    return true;
  }

  function pushBlend(mode) {
    if (state.destroyed || !Number.isInteger(mode) || mode < 0 || mode > 1) return false;
    state.blends.push(state.blend);
    state.blend = mode;
    return true;
  }

  function popBlend() {
    if (state.destroyed || state.blends.length === 0) return false;
    state.blend = state.blends.pop();
    return true;
  }

  function present() {
    if (state.destroyed || state.deviceStatus !== "ready" || state.width === 0 || state.height === 0 || state.clips.length !== 0 || state.blends.length !== 0) return false;
    try {
      const encoder = device.createCommandEncoder();
      const pass = encoder.beginRenderPass({colorAttachments: [{view: context.getCurrentTexture().createView(), clearValue: state.clear, loadOp: "clear", storeOp: "store"}]});
      if (state.vertexCount > 0) device.queue.writeBuffer(vertexBuffer, 0, state.vertices.buffer, 0, state.vertexCount * floatsPerVertex * 4);
      if (state.spriteVertexCount > 0) device.queue.writeBuffer(spriteBuffer, 0, state.spriteVertices.buffer, 0, state.spriteVertexCount * spriteFloatsPerVertex * 4);
      for (let index = 0; index < state.batchCount; index += 1) {
        const batch = batches[index];
        if (batch.kind === "primitive") {
          pass.setPipeline(pipelines[batch.blend]);
          pass.setVertexBuffer(0, vertexBuffer, batch.offset * floatsPerVertex * 4);
        } else {
          pass.setPipeline(spritePipelines[batch.blend]);
          pass.setBindGroup(0, batch.texture.bindGroup);
          pass.setVertexBuffer(0, spriteBuffer, batch.offset * spriteFloatsPerVertex * 4);
        }
        pass.draw(batch.count);
      }
      pass.end();
      device.queue.submit([encoder.finish()]);
      state.vertexCount = 0;
      state.spriteVertexCount = 0;
      state.batchCount = 0;
      return true;
    } catch {
      state.deviceStatus = "presentation_failed";
      return false;
    }
  }

  function destroy() {
    if (state.destroyed) return;
    state.destroyed = true;
    context.unconfigure?.();
    vertexBuffer.destroy?.();
    spriteBuffer.destroy?.();
    for (const texture of state.textures.values()) texture.texture.destroy?.();
    state.textures.clear();
    device.destroy?.();
  }

  return {
    adapter,
    device,
    context,
    format,
    resize,
    clear,
    drawRect,
    uploadTexture,
    destroyTexture,
    drawSprite,
    pushClip,
    popClip,
    pushBlend,
    popBlend,
    present,
    destroy,
    isLost: () => state.deviceStatus === "lost",
    diagnostic: () => ({adapter_status: state.adapterStatus, device_status: state.deviceStatus, canvas_format: format, logical_width: state.width, logical_height: state.height}),
  };
}
