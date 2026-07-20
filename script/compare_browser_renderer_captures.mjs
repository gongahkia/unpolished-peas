import {mkdirSync, mkdtempSync, readFileSync, writeFileSync} from "node:fs";
import {join} from "node:path";

const [webglPath, webgpuPath, diagnosticsRoot] = process.argv.slice(2);
if (!webglPath || !webgpuPath || !diagnosticsRoot) throw new Error("usage: compare_browser_renderer_captures.mjs <webgl2.json> <webgpu.json> <diagnostics-root>");

const tolerance = 1;
const webgl2 = JSON.parse(readFileSync(webglPath, "utf8"));
const webgpu = JSON.parse(readFileSync(webgpuPath, "utf8"));

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function writeImage(path, image) {
  if (typeof image !== "string" || !image.startsWith("data:image/png;base64,")) return;
  writeFileSync(path, Buffer.from(image.slice("data:image/png;base64,".length), "base64"));
}

function preserve(reason, comparison) {
  mkdirSync(diagnosticsRoot, {recursive: true});
  const output = mkdtempSync(join(diagnosticsRoot, "run-"));
  writeImage(join(output, "webgl2.png"), webgl2.image);
  writeImage(join(output, "webgpu.png"), webgpu.image);
  writeJson(join(output, "webgl2-renderer-diagnostics.json"), webgl2.diagnostic);
  writeJson(join(output, "webgpu-renderer-diagnostics.json"), webgpu.diagnostic);
  writeJson(join(output, "webgl2-command-trace.json"), webgl2.commands);
  writeJson(join(output, "webgpu-command-trace.json"), webgpu.commands);
  writeJson(join(output, "comparison.json"), {version: 1, reason, tolerance: {per_channel: tolerance}, webgl2: {dimensions: webgl2.dimensions, error: webgl2.error}, webgpu: {dimensions: webgpu.dimensions, error: webgpu.error}, comparison});
  return output;
}

if (!webgl2.ready || !webgpu.ready) {
  const output = preserve("renderer_unavailable", null);
  const unavailable = !webgpu.ready && webgpu.error?.startsWith("requested webgpu, selected");
  console.error(`browser renderer parity ${unavailable ? "unavailable" : "failed"}: diagnostics=${output}`);
  process.exitCode = unavailable ? 69 : 1;
} else if (webgl2.dimensions?.width !== webgpu.dimensions?.width || webgl2.dimensions?.height !== webgpu.dimensions?.height || !Array.isArray(webgl2.pixels) || !Array.isArray(webgpu.pixels) || webgl2.pixels.length !== webgpu.pixels.length) {
  const output = preserve("capture_dimensions_mismatch", null);
  console.error(`browser renderer parity failed: dimensions=${output}`);
  process.exitCode = 1;
} else {
  const mismatches = [];
  let maxDelta = 0;
  for (let index = 0; index < webgl2.pixels.length; index += 1) {
    const delta = Math.abs(webgl2.pixels[index] - webgpu.pixels[index]);
    maxDelta = Math.max(maxDelta, delta);
    if (delta <= tolerance || mismatches.length === 64) continue;
    const pixel = Math.floor(index / 4);
    mismatches.push({x: pixel % webgl2.dimensions.width, y: Math.floor(pixel / webgl2.dimensions.width), channel: index % 4, webgl2: webgl2.pixels[index], webgpu: webgpu.pixels[index], delta});
  }
  if (mismatches.length > 0) {
    const output = preserve("pixel_tolerance_exceeded", {max_delta: maxDelta, mismatches});
    console.error(`browser renderer parity failed: mismatches=${mismatches.length} max_delta=${maxDelta} diagnostics=${output}`);
    process.exitCode = 1;
  } else {
    console.log(`browser renderer parity passed: dimensions=${webgl2.dimensions.width}x${webgl2.dimensions.height} tolerance=${tolerance} max_delta=${maxDelta}`);
  }
}
