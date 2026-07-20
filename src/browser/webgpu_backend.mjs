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
  if (!device?.queue?.submit || !device.createCommandEncoder) throw new WebGpuBackendError("device_unavailable");
  const format = gpu.getPreferredCanvasFormat();
  if (typeof format !== "string" || format.length === 0) throw new WebGpuBackendError("canvas_format_unavailable");
  const state = {adapterStatus: "ready", deviceStatus: "ready", destroyed: false, width: 0, height: 0, clear: colorFromPacked(0xff000000)};
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

  function present() {
    if (state.destroyed || state.deviceStatus !== "ready" || state.width === 0 || state.height === 0) return false;
    try {
      const encoder = device.createCommandEncoder();
      const pass = encoder.beginRenderPass({colorAttachments: [{view: context.getCurrentTexture().createView(), clearValue: state.clear, loadOp: "clear", storeOp: "store"}]});
      pass.end();
      device.queue.submit([encoder.finish()]);
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
    device.destroy?.();
  }

  return {
    adapter,
    device,
    context,
    format,
    resize,
    clear,
    present,
    destroy,
    isLost: () => state.deviceStatus === "lost",
    diagnostic: () => ({adapter_status: state.adapterStatus, device_status: state.deviceStatus, canvas_format: format, logical_width: state.width, logical_height: state.height}),
  };
}
