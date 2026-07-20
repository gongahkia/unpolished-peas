import assert from "node:assert/strict";
import {selectRenderer} from "../src/browser/renderer_selection.mjs";

const readyHost = {initializeWebGpu: async (width, height) => ({adapter_status: "ready", device_status: "ready", width, height})};
assert.deepEqual(await selectRenderer("webgl2", readyHost, 320, 180), {selectedRenderer: "webgl2", fallbackReason: null, webgpuCapability: "not_checked", adapterStatus: "not_applicable", deviceStatus: "not_applicable"});
assert.deepEqual(await selectRenderer("webgpu", readyHost, 320, 180), {selectedRenderer: "webgpu", fallbackReason: null, webgpuCapability: "available", adapterStatus: "ready", deviceStatus: "ready"});
assert.deepEqual(await selectRenderer("auto", readyHost, 320, 180), {selectedRenderer: "webgpu", fallbackReason: null, webgpuCapability: "available", adapterStatus: "ready", deviceStatus: "ready"});
const unavailableHost = {initializeWebGpu: async () => { throw {code: "adapter_unavailable"}; }};
assert.deepEqual(await selectRenderer("webgpu", unavailableHost, 320, 180), {selectedRenderer: null, fallbackReason: "adapter_unavailable", webgpuCapability: "unavailable", adapterStatus: "unavailable", deviceStatus: "not_checked"});
assert.deepEqual(await selectRenderer("auto", unavailableHost, 320, 180), {selectedRenderer: "webgl2", fallbackReason: "adapter_unavailable_fallback", webgpuCapability: "unavailable", adapterStatus: "unavailable", deviceStatus: "not_checked"});
assert.equal((await selectRenderer("invalid", readyHost, 320, 180)).fallbackReason, "unknown_renderer_request");
console.log("browser-renderer-selection passed");
