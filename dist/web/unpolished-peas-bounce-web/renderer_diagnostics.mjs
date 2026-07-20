export const RendererDiagnosticVersion = 1;

export function browserTarget(navigatorRef = globalThis.navigator) {
  const userAgent = navigatorRef?.userAgent;
  if (typeof userAgent !== "string") return "unknown";
  if (/Firefox\//.test(userAgent)) return "firefox";
  if (/Chrom(e|ium)\//.test(userAgent) || /Edg\//.test(userAgent)) return "chromium";
  if (/Safari\//.test(userAgent) && /Version\//.test(userAgent)) return "safari";
  return "unknown";
}

export function rendererDiagnostic({requestedRenderer, selectedRenderer, fallbackReason, recoveryInstruction, target, webgl2Capability, contextStatus, recoveryState}) {
  return {
    version: RendererDiagnosticVersion,
    requested_renderer: requestedRenderer,
    selected_renderer: selectedRenderer,
    fallback_reason: fallbackReason,
    recovery_instruction: recoveryInstruction,
    browser_target: target,
    capabilities: {webgl2: webgl2Capability, webgpu: "unsupported"},
    context_status: contextStatus,
    adapter_status: "not_applicable",
    device_status: "not_applicable",
    recovery_state: {phase: recoveryState.phase, generation: recoveryState.generation, recoveries: recoveryState.recoveries},
  };
}
