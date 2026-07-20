import {mkdirSync, mkdtempSync, readFileSync, writeFileSync} from "node:fs";
import {join} from "node:path";

const [desktopPath, browserDir, diagnosticsRoot, fixturePath] = process.argv.slice(2);
if (!desktopPath || !browserDir || !diagnosticsRoot || !fixturePath) throw new Error("usage: compare_renderer_three_backend.mjs <desktop-capture.json> <browser-capture-dir> <diagnostics-root> <fixture.json>");

const tolerance = 1;
const desktop = JSON.parse(readFileSync(desktopPath, "utf8"));
const webgl2 = JSON.parse(readFileSync(join(browserDir, "webgl2.json"), "utf8"));
const webgpu = JSON.parse(readFileSync(join(browserDir, "webgpu.json"), "utf8"));
const webgl2Host = JSON.parse(readFileSync(join(browserDir, "webgl2-host.json"), "utf8"));
const webgpuHost = JSON.parse(readFileSync(join(browserDir, "webgpu-host.json"), "utf8"));
const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function writeImage(path, image) {
  if (typeof image === "string" && image.startsWith("data:image/png;base64,")) writeFileSync(path, Buffer.from(image.slice("data:image/png;base64,".length), "base64"));
}

function validCapture(value) {
  return value?.dimensions && Number.isInteger(value.dimensions.width) && Number.isInteger(value.dimensions.height) && Array.isArray(value.pixels) && value.pixels.every((channel) => Number.isInteger(channel) && channel >= 0 && channel <= 255);
}

function compare(name, capture) {
  if (!validCapture(capture) || capture.dimensions.width !== desktop.dimensions.width || capture.dimensions.height !== desktop.dimensions.height || capture.pixels.length !== desktop.pixels.length) return {name, max_delta: null, mismatches: [{reason: "capture_dimensions_mismatch"}]};
  const mismatches = [];
  let maxDelta = 0;
  for (let index = 0; index < desktop.pixels.length; index += 1) {
    const delta = Math.abs(desktop.pixels[index] - capture.pixels[index]);
    maxDelta = Math.max(maxDelta, delta);
    if (delta <= tolerance || mismatches.length === 64) continue;
    const pixel = Math.floor(index / 4);
    mismatches.push({x: pixel % desktop.dimensions.width, y: Math.floor(pixel / desktop.dimensions.width), channel: index % 4, desktop: desktop.pixels[index], [name]: capture.pixels[index], delta});
  }
  return {name, max_delta: maxDelta, mismatches};
}

function preserve(reason, comparison) {
  mkdirSync(diagnosticsRoot, {recursive: true});
  const output = mkdtempSync(join(diagnosticsRoot, "run-"));
  writeJson(join(output, "fixture.json"), fixture);
  writeJson(join(output, "desktop-capture.json"), desktop);
  writeJson(join(output, "webgl2-capture.json"), webgl2);
  writeJson(join(output, "webgpu-capture.json"), webgpu);
  writeJson(join(output, "webgl2-host.json"), webgl2Host);
  writeJson(join(output, "webgpu-host.json"), webgpuHost);
  writeImage(join(output, "webgl2.png"), webgl2.image);
  writeImage(join(output, "webgpu.png"), webgpu.image);
  writeJson(join(output, "comparison.json"), {schema_version: 1, reason, tolerance: {per_channel: tolerance}, desktop: desktop.target ?? null, webgl2: {host: webgl2Host, diagnostic: webgl2.diagnostic ?? null}, webgpu: {host: webgpuHost, diagnostic: webgpu.diagnostic ?? null}, comparison});
  return output;
}

const fixtureValid = fixture?.schema_version === 1 && fixture.fixture_version === "v1" && fixture.width === desktop?.dimensions?.width && fixture.height === desktop?.dimensions?.height;
const desktopValid = desktop?.schema_version === 1 && desktop.fixture?.schema_version === 1 && desktop.fixture.fixture_version === fixture?.fixture_version && desktop.target?.renderer === "sdl-gpu" && validCapture(desktop);
const browserValid = webgl2?.ready && webgpu?.ready && webgl2.renderer === "webgl2" && webgpu.renderer === "webgpu";
if (!fixtureValid || !desktopValid || !browserValid) {
  const output = preserve("capture_metadata_invalid", null);
  console.error(`renderer three-backend failed: diagnostics=${output}`);
  process.exitCode = 1;
} else {
  const webgl2Comparison = compare("webgl2", webgl2);
  const webgpuComparison = compare("webgpu", webgpu);
  if (webgl2Comparison.mismatches.length > 0 || webgpuComparison.mismatches.length > 0) {
    const output = preserve("pixel_tolerance_exceeded", {webgl2: webgl2Comparison, webgpu: webgpuComparison});
    console.error(`renderer three-backend failed: diagnostics=${output}`);
    process.exitCode = 1;
  } else {
    console.log(`renderer three-backend passed: dimensions=${desktop.dimensions.width}x${desktop.dimensions.height} tolerance=${tolerance} webgl2_max_delta=${webgl2Comparison.max_delta} webgpu_max_delta=${webgpuComparison.max_delta}`);
  }
}
