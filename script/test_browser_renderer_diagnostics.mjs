import assert from "node:assert/strict";
import {RendererDiagnosticVersion, browserTarget, rendererDiagnostic, webGpuDeviceLostDiagnostic} from "../src/browser/renderer_diagnostics.mjs";

assert.equal(RendererDiagnosticVersion, 1);
assert.equal(browserTarget({userAgent: "Mozilla/5.0 Firefox/140.0"}), "firefox");
assert.equal(browserTarget({userAgent: "Mozilla/5.0 Chrome/140.0 Safari/537.36"}), "chromium");
assert.equal(browserTarget({userAgent: "Mozilla/5.0 Version/18.0 Safari/605.1.15"}), "safari");
assert.equal(browserTarget({userAgent: "unknown"}), "unknown");
const diagnostic = rendererDiagnostic({
  requestedRenderer: "webgpu",
  selectedRenderer: null,
  fallbackReason: "forced_renderer_unsupported",
  recoveryInstruction: "Use ?renderer=webgl2.",
  target: "chromium",
  webgl2Capability: "not_checked",
  contextStatus: "not_checked",
  recoveryState: {phase: "idle", generation: 0, recoveries: 0, scheduledFrames: 0},
});
assert.deepEqual(diagnostic, {
  version: 1,
  requested_renderer: "webgpu",
  selected_renderer: null,
  fallback_reason: "forced_renderer_unsupported",
  recovery_instruction: "Use ?renderer=webgl2.",
  browser_target: "chromium",
  capabilities: {webgl2: "not_checked", webgpu: "unsupported"},
  context_status: "not_checked",
  adapter_status: "not_applicable",
  device_status: "not_applicable",
  recovery_state: {phase: "idle", generation: 0, recoveries: 0},
});
assert.equal("user_agent" in diagnostic, false);
assert.equal("adapter" in diagnostic, false);
assert.equal("device" in diagnostic, false);
const lost = webGpuDeviceLostDiagnostic({...diagnostic, selected_renderer: "webgpu", capabilities: {webgl2: "not_checked", webgpu: "available"}}, "chromium", {phase: "device_lost", generation: 1, recoveries: 0});
assert.deepEqual(lost, {...diagnostic, selected_renderer: "webgpu", fallback_reason: "device_lost", recovery_instruction: "Reload the package to create a new WebGPU device.", capabilities: {webgl2: "not_checked", webgpu: "available"}, context_status: "device_lost", adapter_status: "ready", device_status: "lost", recovery_state: {phase: "device_lost", generation: 1, recoveries: 0}});
