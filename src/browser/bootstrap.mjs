import {createBrowserHost, Status} from "./host.mjs";
import {browserTarget, rendererDiagnostic} from "./renderer_diagnostics.mjs";

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

function unavailable(reason, instruction, contextStatus, webgl2Capability) {
  const diagnostic = rendererDiagnostic({
    requestedRenderer,
    selectedRenderer: null,
    fallbackReason: reason,
    recoveryInstruction: instruction,
    target,
    webgl2Capability,
    contextStatus,
    recoveryState: host.lifecycle(),
  });
  publish(diagnostic);
  throw new Error(`unpolished-peas browser: ${reason}; ${instruction}`);
}

if (requestedRenderer !== "webgl2") {
  if (requestedRenderer === "webgpu") unavailable("forced_renderer_unsupported", "Use ?renderer=webgl2; WebGPU is unsupported by the current v0.1 capability matrix.", "not_checked", "not_checked");
  unavailable("unknown_renderer_request", "Use ?renderer=webgl2; this package supports only WebGL 2.", "not_checked", "not_checked");
}

try {
  const result = await instantiate("./unpolished-peas.wasm", host.imports);
  const runtime = result.instance.exports;
  if (!host.attachRuntime(runtime)) unavailable("runtime_abi_invalid", "Rebuild the browser package from a matching checkout.", "not_initialized", "not_checked");
  const width = Math.max(1, Math.floor(canvas.clientWidth || canvas.width || 320));
  const height = Math.max(1, Math.floor(canvas.clientHeight || canvas.height || 180));
  if (runtime.up_browser_gl_context_create(width, height) !== Status.ok) unavailable("webgl2_context_unavailable", "Use a browser with WebGL 2 enabled, then reload.", "unavailable", "unavailable");
  if (runtime.up_browser_init(width, height) !== Status.ok) unavailable("runtime_initialization_failed", "Reload the package; if it persists, rebuild from the same checkout.", "ready", "available");
  const diagnostic = rendererDiagnostic({
    requestedRenderer,
    selectedRenderer: "webgl2",
    fallbackReason: null,
    recoveryInstruction: null,
    target,
    webgl2Capability: "available",
    contextStatus: "ready",
    recoveryState: host.lifecycle(),
  });
  publish(diagnostic, runtime, "webgl2");
} catch (error) {
  if (window.unpolishedPeas?.rendererDiagnostic) throw error;
  unavailable("browser_runtime_load_failed", "Reload the package; if it persists, rebuild from the same checkout.", "not_initialized", "not_checked");
}
