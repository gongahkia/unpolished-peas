import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {benchmarkWorkloadCatalog, browserTimerLimitations, browserVersion, unavailableBrowserWorkloadArtifact} from "../src/browser/workload_runner.mjs";

const catalog = JSON.parse(await readFile(new URL("../benchmarks/workloads/v1.json", import.meta.url), "utf8"));
const memory = new WebAssembly.Memory({initial: 1});
let nextHandle = 1;
let now = 0;
const calls = [];
const runtime = {
  up_browser_gl_context_create: (...args) => { calls.push(["context", ...args]); return 0; },
  up_browser_gl_resource_create: () => nextHandle++,
  up_browser_gl_resource_destroy: (...args) => calls.push(["destroy", ...args]),
  up_browser_texture_upload: (...args) => { calls.push(["upload", ...args]); return 0; },
  up_browser_clear: () => 0,
  up_browser_draw_rect: () => 0,
  up_browser_draw_sprite: () => 0,
  up_browser_draw_text: () => 0,
  up_browser_push_clip: () => 0,
  up_browser_pop_clip: () => 0,
  up_browser_present: () => 0,
};
const artifact = benchmarkWorkloadCatalog(runtime, {memory}, catalog, {browser: {name: "chromium", version: "123.4.5.6"}, renderer: "webgpu", now: () => { now += 0.25; return now; }});
assert.equal(artifact.schema_version, 1);
assert.equal(artifact.status, "ok");
assert.deepEqual(artifact.target, {os: "browser", architecture: "browser", browser: {name: "chromium", version: "123.4.5.6"}, renderer: "webgpu"});
assert.equal(artifact.workload_version, "v1");
assert.equal(artifact.workloads.length, 6);
assert.equal(artifact.diagnostics.total_frames, 120);
assert.deepEqual(artifact.timer.limitations, browserTimerLimitations);
assert.equal(artifact.workloads[0].metrics.frame_time_ns, 250000);
assert.equal(artifact.workloads[0].metrics.command_count, 82);
assert.equal(artifact.workloads[0].metrics.frame_allocation_events, null);
assert.equal(artifact.workloads[0].metric_availability.frame_allocated_bytes, "unavailable");
assert.equal(calls.filter(([name]) => name === "context").length, 6);
assert.equal(browserVersion("chromium", "Mozilla/5.0 Chrome/123.4.5.6 Safari/537.36"), "123.4.5.6");
assert.equal(browserVersion("firefox", "Mozilla/5.0 Firefox/124.0"), "124.0");
assert.equal(browserVersion("webkit", "Mozilla/5.0 Version/17.4 Safari/605.1.15"), "17.4");
const unavailable = unavailableBrowserWorkloadArtifact({browser: {name: "firefox", version: "124.0"}, renderer: "webgpu", workloadVersion: "v1", diagnostic: {fallback_reason: "webgpu_unavailable"}});
assert.equal(unavailable.status, "unavailable");
assert.equal(unavailable.workloads.length, 0);
assert.equal(unavailable.diagnostics.renderer_diagnostic.fallback_reason, "webgpu_unavailable");
console.log("browser-workload-benchmark passed");
