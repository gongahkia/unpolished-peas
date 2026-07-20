import {mkdirSync, mkdtempSync, readFileSync, writeFileSync} from "node:fs";
import {join} from "node:path";
import {compareRendererContractCapture} from "../src/browser/renderer_contract_runner.mjs";

const [webglPath, webgpuPath, diagnosticsRoot, fixturePath] = process.argv.slice(2);
if (!webglPath || !webgpuPath || !diagnosticsRoot) throw new Error("usage: compare_browser_renderer_captures.mjs <webgl2.json> <webgpu.json> <diagnostics-root>");

const tolerance = 1;
const webgl2 = JSON.parse(readFileSync(webglPath, "utf8"));
const webgpu = JSON.parse(readFileSync(webgpuPath, "utf8"));
const fixture = fixturePath ? JSON.parse(readFileSync(fixturePath, "utf8")) : null;

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
  const reference = fixture ? {
    webgl2: compareRendererContractCapture(fixture, webgl2),
    webgpu: compareRendererContractCapture(fixture, webgpu),
  } : null;
  const referenceSummary = reference ? {
    webgl2: {dimensions: reference.webgl2.expected.dimensions, max_delta: reference.webgl2.max_delta, mismatches: reference.webgl2.mismatches},
    webgpu: {dimensions: reference.webgpu.expected.dimensions, max_delta: reference.webgpu.max_delta, mismatches: reference.webgpu.mismatches},
  } : null;
  if (mismatches.length > 0 || reference?.webgl2.mismatches.length > 0 || reference?.webgpu.mismatches.length > 0) {
    const reason = mismatches.length > 0 ? "pixel_tolerance_exceeded" : "contract_reference_mismatch";
    const output = preserve(reason, {browser_parity: {max_delta: maxDelta, mismatches}, contract_reference: referenceSummary});
    console.error(`browser renderer parity failed: mismatches=${mismatches.length} max_delta=${maxDelta} diagnostics=${output}`);
    process.exitCode = 1;
  } else {
    console.log(`browser renderer parity passed: dimensions=${webgl2.dimensions.width}x${webgl2.dimensions.height} tolerance=${tolerance} max_delta=${maxDelta}${reference ? ` reference_max_delta=${Math.max(reference.webgl2.max_delta, reference.webgpu.max_delta)}` : ""}`);
  }
}
