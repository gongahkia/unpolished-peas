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
const floatsPerVertex = 6;
const verticesPerRectangle = 6;
const vertexShader = `
struct Output { @builtin(position) position: vec4f, @location(0) color: vec4f }
@vertex fn main(@location(0) position: vec2f, @location(1) color: vec4f) -> Output { return Output(vec4f(position, 0.0, 1.0), color); }
@fragment fn fragment(input: Output) -> @location(0) vec4f { return input.color; }
`;

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
  if (!device?.queue?.submit || !device.queue.writeBuffer || !device.createCommandEncoder || !device.createShaderModule || !device.createRenderPipeline || !device.createBuffer) throw new WebGpuBackendError("device_unavailable");
  const format = gpu.getPreferredCanvasFormat();
  if (typeof format !== "string" || format.length === 0) throw new WebGpuBackendError("canvas_format_unavailable");
  const shader = device.createShaderModule({code: vertexShader});
  const pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: {module: shader, buffers: [{arrayStride: floatsPerVertex * 4, attributes: [{shaderLocation: 0, offset: 0, format: "float32x2"}, {shaderLocation: 1, offset: 8, format: "float32x4"}]}]},
    fragment: {module: shader, targets: [{format, blend: {color: {srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add"}, alpha: {srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add"}}}]},
    primitive: {topology: "triangle-list"},
  });
  const usage = globalThis.GPUBufferUsage?.VERTEX | globalThis.GPUBufferUsage?.COPY_DST || 0x28;
  const vertexBuffer = device.createBuffer({size: maxRectangles * verticesPerRectangle * floatsPerVertex * 4, usage});
  const state = {adapterStatus: "ready", deviceStatus: "ready", destroyed: false, width: 0, height: 0, clear: colorFromPacked(0xff000000), clip: null, clips: [], vertices: new Float32Array(maxRectangles * verticesPerRectangle * floatsPerVertex), vertexCount: 0};
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
    return true;
  }

  function drawRect(x, y, width, height, color) {
    if (state.destroyed || state.deviceStatus !== "ready" || ![x, y, width, height, color].every(Number.isInteger)) return false;
    const rect = state.clip ? intersect({x, y, width, height}, state.clip) : {x, y, width, height};
    if (rect.width <= 0 || rect.height <= 0) return true;
    if (state.vertexCount + verticesPerRectangle > maxRectangles * verticesPerRectangle) return false;
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

  function present() {
    if (state.destroyed || state.deviceStatus !== "ready" || state.width === 0 || state.height === 0) return false;
    try {
      const encoder = device.createCommandEncoder();
      const pass = encoder.beginRenderPass({colorAttachments: [{view: context.getCurrentTexture().createView(), clearValue: state.clear, loadOp: "clear", storeOp: "store"}]});
      if (state.vertexCount > 0) {
        device.queue.writeBuffer(vertexBuffer, 0, state.vertices.buffer, 0, state.vertexCount * floatsPerVertex * 4);
        pass.setPipeline(pipeline);
        pass.setVertexBuffer(0, vertexBuffer);
        pass.draw(state.vertexCount);
      }
      pass.end();
      device.queue.submit([encoder.finish()]);
      state.vertexCount = 0;
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
    pushClip,
    popClip,
    present,
    destroy,
    isLost: () => state.deviceStatus === "lost",
    diagnostic: () => ({adapter_status: state.adapterStatus, device_status: state.deviceStatus, canvas_format: format, logical_width: state.width, logical_height: state.height}),
  };
}
