import assert from "node:assert/strict";
import {execFile} from "node:child_process";
import {mkdtemp, readFile, rm} from "node:fs/promises";
import {createServer} from "node:http";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {fileURLToPath} from "node:url";
import {promisify} from "node:util";
import {selectedRenderers, validateRenderer} from "./safari_webdriver.mjs";

const base = {version: 1, browser_target: "safari", capabilities: {webgl2: "available", webgpu: "unsupported"}, context_status: "ready", adapter_status: "not_applicable", device_status: "not_applicable"};
assert.equal(validateRenderer({...base, requested_renderer: "webgl2", selected_renderer: "webgl2", fallback_reason: null}, "webgl2"), "available");
assert.equal(validateRenderer({...base, requested_renderer: "webgpu", selected_renderer: null, fallback_reason: "webgpu_unavailable"}, "webgpu"), "unavailable");
assert.throws(() => validateRenderer({...base, requested_renderer: "webgpu", selected_renderer: "webgl2", fallback_reason: "webgpu_fallback"}, "webgpu"), /silently downgraded/);
assert.deepEqual(selectedRenderers(), ["webgl2", "webgpu"]);
assert.deepEqual(selectedRenderers("webgpu"), ["webgpu"]);
assert.throws(() => selectedRenderers("webgl2 invalid"), /invalid forced renderer selection/);

// Exercise a failed smoke through WebDriver's HTTP boundary. Failures must
// retain the browser state and screenshot before the session is deleted.
const directory = await mkdtemp(join(tmpdir(), "peas-safari-contract-"));
const diagnostic = {...base, requested_renderer: "webgl2", selected_renderer: "webgl2", fallback_reason: null};
const storage = {phase: "failed", lastError: "initialization_failed"};
let deleted = false;
let framePolls = 0;
let pngCaptureAvailable = true;
let healthyHost = false;
let badPixel = false;
let renderChecks = 0;
const navigations = [];
let unexpected = null;
const server = createServer(async (request, response) => {
  let body = "";
  for await (const chunk of request) body += chunk;
  const value = body ? JSON.parse(body) : null;
  let result = null;
  if (request.url === "/status") result = {ready: true};
  else if (request.url === "/session") result = {sessionId: "fixture", capabilities: {browserVersion: "26.0"}};
  else if (request.url === "/session/fixture" && request.method === "DELETE") deleted = true;
  else if (request.url.endsWith("/element")) result = {"element-6066-11e4-a52e-4f735466cecf": "canvas"};
  else if (request.url.endsWith("/screenshot")) result = Buffer.from("screenshot fixture").toString("base64");
  else if (request.url.endsWith("/url")) navigations.push(value.url);
  else if (request.url.endsWith("/execute/sync")) {
    if (value.script.includes("probeWebGlCapture")) result = {context_lost: false, error: 0, pixel: [255, 0, 0, 255], png_capture_available: pngCaptureAvailable};
    else if (value.script.includes("webGlRenderContract")) {
      renderChecks += 1;
      result = {statuses: [0, 0, 0, 0], pixel: badPixel ? [0, 0, 0, 0] : [255, 0, 0, 255], error: 0, context_lost: false};
    } else if (value.script.includes("runtime_audio_state")) result = healthyHost ? {
      storage: {phase: "ready"}, audio: {phase: "active", state: 0}, runtime_audio_state: 0,
      frame_capture: false, frame_capture_result: null, diagnostic_emitted: true,
      renderer_diagnostic_matches: true, lifecycle: {scheduledFrames: 1},
    } : {storage};
    else if (value.script.includes("user_agent:")) result = {user_agent: "Safari fixture", platform: "fixture", renderer: "webgl2", diagnostic, artifacts: [], storage: healthyHost ? {phase: "ready"} : storage};
    else if (value.script.includes("dataset.game")) result = "bounce";
    else if (value.script.startsWith("return window.unpolishedPeas?.rendererDiagnostic")) result = diagnostic;
    else if (value.script.includes("captureFrame")) result = ++framePolls > 1;
    else if (value.script.includes("input") || value.script.includes("return Boolean")) result = true;
    else unexpected = value.script;
  } else if (!request.url.endsWith("/url") && !request.url.endsWith("/click") && !request.url.endsWith("/actions")) unexpected = request.url;
  response.writeHead(200, {"content-type": "application/json"});
  response.end(JSON.stringify({value: result}));
});
try {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const run = (output) => promisify(execFile)(process.execPath, [fileURLToPath(new URL("./safari_webdriver.mjs", import.meta.url)), "http://fixture.invalid", output], {
    env: {...process.env, UP_SAFARI_GAME: "bounce", UP_SAFARI_RENDERERS: "webgl2", UP_SAFARI_WEBDRIVER_URL: `http://127.0.0.1:${server.address().port}`},
    timeout: 10000,
  }).catch((error) => error);
  const failedDirectory = join(directory, "failed-storage");
  const failure = await run(failedDirectory);
  assert.equal(unexpected, null, `unexpected WebDriver request: ${unexpected}`);
  assert.equal(failure.code, 1);
  assert.match(failure.stderr, /Safari storage:.*initialization_failed/);
  const artifact = JSON.parse(await readFile(join(failedDirectory, "safari-webgl2-artifacts.json"), "utf8"));
  assert.deepEqual(artifact.storage, storage);
  assert.deepEqual(artifact.diagnostic, diagnostic);
  assert.equal(await readFile(join(failedDirectory, artifact.screenshot), "utf8"), "screenshot fixture");
  assert.equal(deleted, true, "failed Safari sessions must be closed");
  assert.equal(framePolls, 2, "Safari must wait for canvas readback to become available");
  assert.deepEqual(navigations, ["http://fixture.invalid/__peas-capture-probe__.html", "http://fixture.invalid?renderer=webgl2"], "probe canvas export on the package origin before loading Peas");

  // Independently unavailable canvas PNG export may use nullable capture, while
  // real Peas rendering still has to produce the expected pixels.
  pngCaptureAvailable = false;
  healthyHost = true;
  deleted = false;
  framePolls = 0;
  const limitedDirectory = join(directory, "unavailable-png");
  const limited = await run(limitedDirectory);
  assert.equal(limited.code, undefined, limited.stderr);
  assert.match(limited.stdout, /PNG export is unavailable before Peas loads/);
  assert.equal(framePolls, 0);
  assert.equal(deleted, true);
  const limitedArtifact = JSON.parse(await readFile(join(limitedDirectory, "safari-webgl2-artifacts.json"), "utf8"));
  assert.equal(limitedArtifact.capture_probe.png_capture_available, false);
  assert.deepEqual(JSON.parse(await readFile(join(limitedDirectory, "webgl2-readback.json"), "utf8")).pixel, [255, 0, 0, 255]);

  badPixel = true;
  const brokenRenderer = await run(join(directory, "broken-renderer"));
  assert.equal(brokenRenderer.code, 1);
  assert.match(brokenRenderer.stderr, /Safari Peas WebGL pixel output/);

  badPixel = false;
  pngCaptureAvailable = true;
  const brokenCapture = await run(join(directory, "broken-capture"));
  assert.equal(brokenCapture.code, 1);
  assert.match(brokenCapture.stderr, /Safari frame capture did not return a PNG/);
  assert.equal(renderChecks, 4, "PNG availability must never bypass Peas renderer checks");
  assert.equal(unexpected, null);
} finally {
  await new Promise((resolve) => server.close(resolve));
  await rm(directory, {recursive: true, force: true});
}
console.log("Safari WebDriver contract passed");
