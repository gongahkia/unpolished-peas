export const RendererDiagnosticVersion = 1;

export function browserTarget(navigatorRef = globalThis.navigator) {
  const userAgent = navigatorRef?.userAgent;
  if (typeof userAgent !== "string") return "unknown";
  if (/Firefox\//.test(userAgent)) return "firefox";
  if (/Chrom(e|ium)\//.test(userAgent) || /Edg\//.test(userAgent)) return "chromium";
  if (/Safari\//.test(userAgent) && /Version\//.test(userAgent)) return "safari";
  return "unknown";
}

export function rendererDiagnostic({requestedRenderer, selectedRenderer, fallbackReason, recoveryInstruction, target, webgl2Capability, webgpuCapability = "unsupported", contextStatus, adapterStatus = "not_applicable", deviceStatus = "not_applicable", recoveryState}) {
  return {
    version: RendererDiagnosticVersion,
    requested_renderer: requestedRenderer,
    selected_renderer: selectedRenderer,
    fallback_reason: fallbackReason,
    recovery_instruction: recoveryInstruction,
    browser_target: target,
    capabilities: {webgl2: webgl2Capability, webgpu: webgpuCapability},
    context_status: contextStatus,
    adapter_status: adapterStatus,
    device_status: deviceStatus,
    recovery_state: {phase: recoveryState.phase, generation: recoveryState.generation, recoveries: recoveryState.recoveries},
  };
}

export function webGpuDeviceLostDiagnostic(previous, target, recoveryState) {
  return rendererDiagnostic({
    requestedRenderer: previous.requested_renderer,
    selectedRenderer: "webgpu",
    fallbackReason: "device_lost",
    recoveryInstruction: "Reload the package to create a new WebGPU device.",
    target,
    webgl2Capability: previous.capabilities.webgl2,
    webgpuCapability: "available",
    contextStatus: "device_lost",
    adapterStatus: "ready",
    deviceStatus: "lost",
    recoveryState,
  });
}
