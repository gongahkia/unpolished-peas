import {createBrowserHost, Status} from "./host.mjs";
import {browserTarget, rendererDiagnostic, webGpuDeviceLostDiagnostic} from "./renderer_diagnostics.mjs";
import {selectRenderer} from "./renderer_selection.mjs";

async function instantiate(url, imports) {
  try {
    return await WebAssembly.instantiateStreaming(fetch(url), imports);
  } catch {
    return WebAssembly.instantiate(await (await fetch(url)).arrayBuffer(), imports);
  }
}

const canvas = document.querySelector("canvas[data-unpolished-peas]");
if (!canvas) throw new Error("unpolished-peas browser: missing canvas");
const requestedRenderer = new URLSearchParams(globalThis.location?.search ?? "").get("renderer") ?? "webgl2";
const host = createBrowserHost({canvas});
const target = browserTarget();

function publish(diagnostic, runtime = null, selectedRenderer = null) {
  host.setRendererDiagnostic(diagnostic);
  window.unpolishedPeas = {host, runtime, renderer: selectedRenderer, rendererDiagnostic: diagnostic};
}

host.onWebGpuDeviceLost(() => {
  const previous = window.unpolishedPeas?.rendererDiagnostic;
  if (!previous || previous.selected_renderer !== "webgpu") return;
  const diagnostic = webGpuDeviceLostDiagnostic(previous, target, host.lifecycle());
  publish(diagnostic, window.unpolishedPeas.runtime, "webgpu");
});

function unavailable(reason, instruction, contextStatus, webgl2Capability, webgpuCapability = "not_checked", adapterStatus = "not_applicable", deviceStatus = "not_applicable") {
  const diagnostic = rendererDiagnostic({
    requestedRenderer,
    selectedRenderer: null,
    fallbackReason: reason,
    recoveryInstruction: instruction,
    target,
    webgl2Capability,
    webgpuCapability,
    contextStatus,
    adapterStatus,
    deviceStatus,
    recoveryState: host.lifecycle(),
  });
  publish(diagnostic);
  throw new Error(`unpolished-peas browser: ${reason}; ${instruction}`);
}

try {
  const width = Math.max(1, Math.floor(canvas.clientWidth || canvas.width || 320));
  const height = Math.max(1, Math.floor(canvas.clientHeight || canvas.height || 180));
  const selection = await selectRenderer(requestedRenderer, host, width, height);
  if (!selection.selectedRenderer) {
    const instruction = selection.fallbackReason === "unknown_renderer_request" ? "Use ?renderer=auto, ?renderer=webgpu, or ?renderer=webgl2." : "Use ?renderer=webgl2 or enable WebGPU, then reload.";
    unavailable(selection.fallbackReason, instruction, "unavailable", "not_checked", selection.webgpuCapability, selection.adapterStatus, selection.deviceStatus);
  }
  const result = await instantiate("./unpolished-peas.wasm", host.imports);
  const runtime = result.instance.exports;
  if (!host.attachRuntime(runtime)) unavailable("runtime_abi_invalid", "Rebuild the browser package from a matching checkout.", "not_initialized", "not_checked");
  if (runtime.up_browser_gl_context_create(width, height) !== Status.ok) unavailable(`${selection.selectedRenderer}_context_unavailable`, `Use a browser with ${selection.selectedRenderer === "webgpu" ? "WebGPU" : "WebGL 2"} enabled, then reload.`, "unavailable", selection.selectedRenderer === "webgl2" ? "unavailable" : "not_checked", selection.webgpuCapability, selection.adapterStatus, selection.deviceStatus);
  if (runtime.up_browser_init(width, height) !== Status.ok) unavailable("runtime_initialization_failed", "Reload the package; if it persists, rebuild from the same checkout.", "ready", selection.selectedRenderer === "webgl2" ? "available" : "not_checked", selection.webgpuCapability, selection.adapterStatus, selection.deviceStatus);
  const diagnostic = rendererDiagnostic({
    requestedRenderer,
    selectedRenderer: selection.selectedRenderer,
    fallbackReason: selection.fallbackReason,
    recoveryInstruction: null,
    target,
    webgl2Capability: selection.selectedRenderer === "webgl2" ? "available" : "not_checked",
    webgpuCapability: selection.webgpuCapability,
    contextStatus: "ready",
    adapterStatus: selection.adapterStatus,
    deviceStatus: selection.deviceStatus,
    recoveryState: host.lifecycle(),
  });
  publish(diagnostic, runtime, selection.selectedRenderer);
} catch (error) {
  if (window.unpolishedPeas?.rendererDiagnostic) throw error;
  unavailable("browser_runtime_load_failed", "Reload the package; if it persists, rebuild from the same checkout.", "not_initialized", "not_checked");
}
