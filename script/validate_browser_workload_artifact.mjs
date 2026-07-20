import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {browserTimerLimitations} from "../src/browser/workload_runner.mjs";

const [path, expectedBrowser, expectedRenderer] = process.argv.slice(2);
if (!path || !expectedBrowser || !expectedRenderer) throw new Error("usage: validate_browser_workload_artifact.mjs <path> <browser> <renderer>");

const artifact = JSON.parse(await readFile(path, "utf8"));
assert.equal(artifact.schema_version, 1);
assert.ok(["ok", "unavailable"].includes(artifact.status));
assert.equal(artifact.target.os, "browser");
assert.equal(artifact.target.architecture, "browser");
assert.equal(artifact.target.browser.name, expectedBrowser);
assert.equal(typeof artifact.target.browser.version, "string");
assert.ok(artifact.target.browser.version.length > 0);
assert.equal(artifact.target.renderer, expectedRenderer);
assert.equal(artifact.workload_version, "v1");
assert.equal(artifact.timer.clock, "performance.now");
assert.equal(artifact.timer.unit, "nanoseconds");
assert.equal(artifact.timer.measurement, "cpu_submission");
assert.deepEqual(artifact.timer.limitations, browserTimerLimitations);
if (artifact.status === "unavailable") {
  assert.deepEqual(artifact.workloads, []);
  assert.ok(Object.hasOwn(artifact.diagnostics, "renderer_diagnostic"));
  console.log(`browser workload artifact unavailable: browser=${expectedBrowser} renderer=${expectedRenderer}`);
  process.exitCode = 69;
} else {
  const expected = ["primitive_fill", "sprite_batching", "alpha_blend", "clipping", "text", "mixed_frame"];
  assert.deepEqual(artifact.workloads.map((workload) => workload.id), expected);
  for (const workload of artifact.workloads) {
    assert.deepEqual(workload.resolution, {width: 160, height: 90});
    assert.equal(workload.warmup_frames, 4);
    assert.equal(workload.sample_count, 16);
    assert.ok(Number.isInteger(workload.metrics.frame_time_ns) && workload.metrics.frame_time_ns >= 0);
    assert.ok(Number.isInteger(workload.metrics.command_count) && workload.metrics.command_count > 0);
    assert.equal(workload.metrics.frame_allocation_events, null);
    assert.equal(workload.metrics.frame_allocated_bytes, null);
    assert.deepEqual(workload.metric_availability, {frame_time_ns: "measured_cpu_submission", command_count: "measured", frame_allocation_events: "unavailable", frame_allocated_bytes: "unavailable"});
  }
  assert.equal(artifact.diagnostics.total_frames, 120);
  console.log(`browser workload artifact valid: browser=${expectedBrowser} renderer=${expectedRenderer}`);
}
