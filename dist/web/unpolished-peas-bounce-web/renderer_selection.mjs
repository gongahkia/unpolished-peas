function unavailable(error) {
  return {
    selectedRenderer: null,
    fallbackReason: error?.code ?? "webgpu_initialization_failed",
    webgpuCapability: "unavailable",
    adapterStatus: error?.code?.startsWith("adapter_") ? "unavailable" : "not_checked",
    deviceStatus: error?.code?.startsWith("device_") ? "unavailable" : "not_checked",
  };
}

export async function selectRenderer(requestedRenderer, host, width, height) {
  if (requestedRenderer === "webgl2") return {selectedRenderer: "webgl2", fallbackReason: null, webgpuCapability: "not_checked", adapterStatus: "not_applicable", deviceStatus: "not_applicable"};
  if (requestedRenderer !== "auto" && requestedRenderer !== "webgpu") return {selectedRenderer: null, fallbackReason: "unknown_renderer_request", webgpuCapability: "not_checked", adapterStatus: "not_applicable", deviceStatus: "not_applicable"};
  try {
    const diagnostic = await host.initializeWebGpu(width, height);
    if (!diagnostic) return requestedRenderer === "auto" ? {selectedRenderer: "webgl2", fallbackReason: "webgpu_initialization_failed_fallback", webgpuCapability: "unavailable", adapterStatus: "not_checked", deviceStatus: "not_checked"} : unavailable();
    return {selectedRenderer: "webgpu", fallbackReason: null, webgpuCapability: "available", adapterStatus: diagnostic.adapter_status, deviceStatus: diagnostic.device_status};
  } catch (error) {
    if (requestedRenderer === "auto") {
      const failure = unavailable(error);
      return {...failure, selectedRenderer: "webgl2", fallbackReason: `${failure.fallbackReason}_fallback`};
    }
    return unavailable(error);
  }
}
