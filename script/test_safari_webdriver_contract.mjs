import assert from "node:assert/strict";
import {selectedRenderers, validateRenderer} from "./safari_webdriver.mjs";

const base = {version: 1, browser_target: "safari", capabilities: {webgl2: "available", webgpu: "unsupported"}, context_status: "ready", adapter_status: "not_applicable", device_status: "not_applicable"};
assert.equal(validateRenderer({...base, requested_renderer: "webgl2", selected_renderer: "webgl2", fallback_reason: null}, "webgl2"), "available");
assert.equal(validateRenderer({...base, requested_renderer: "webgpu", selected_renderer: null, fallback_reason: "webgpu_unavailable"}, "webgpu"), "unavailable");
assert.throws(() => validateRenderer({...base, requested_renderer: "webgpu", selected_renderer: "webgl2", fallback_reason: "webgpu_fallback"}, "webgpu"), /silently downgraded/);
assert.deepEqual(selectedRenderers(), ["webgl2", "webgpu"]);
assert.deepEqual(selectedRenderers("webgpu"), ["webgpu"]);
assert.throws(() => selectedRenderers("webgl2 invalid"), /invalid forced renderer selection/);
console.log("Safari WebDriver contract passed");
