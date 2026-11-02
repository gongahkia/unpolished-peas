import assert from "node:assert/strict";
import {mkdir, writeFile} from "node:fs/promises";
import {join} from "node:path";

const elementKey = "element-6066-11e4-a52e-4f735466cecf";

function fail(message) {
  throw new Error(`Safari WebDriver: ${message}`);
}

export function validateRenderer(diagnostic, requested) {
  if (!diagnostic || diagnostic.version !== 1 || diagnostic.browser_target !== "safari" || diagnostic.requested_renderer !== requested) fail(`invalid ${requested} renderer diagnostic`);
  if (requested === "webgl2") {
    if (diagnostic.selected_renderer !== "webgl2" || diagnostic.fallback_reason !== null || diagnostic.capabilities?.webgl2 !== "available" || diagnostic.context_status !== "ready") fail(`forced WebGL 2 was not selected: ${JSON.stringify(diagnostic)}`)
    return "available";
  }
  if (diagnostic.selected_renderer === "webgpu") {
    if (diagnostic.capabilities?.webgpu !== "available" || diagnostic.adapter_status !== "ready" || diagnostic.device_status !== "ready" || diagnostic.context_status !== "ready") fail("forced WebGPU diagnostic is incomplete")
    return "available";
  }
  if (diagnostic.selected_renderer !== null || typeof diagnostic.fallback_reason !== "string" || !diagnostic.fallback_reason) fail("forced WebGPU silently downgraded")
  return "unavailable";
}

export function selectedRenderers(value = "webgl2 webgpu") {
  const renderers = value.split(/\s+/).filter(Boolean);
  if (!renderers.length || new Set(renderers).size !== renderers.length || renderers.some((renderer) => renderer !== "webgl2" && renderer !== "webgpu")) fail(`invalid forced renderer selection: ${value}`);
  return renderers;
}

export class WebDriver {
  constructor(baseUrl) {
    this.baseUrl = baseUrl.replace(/\/$/, "");
    this.sessionId = null;
    this.capabilities = null;
  }

  async request(path, method = "GET", value) {
    const response = await fetch(`${this.baseUrl}${path}`, {
      method,
      headers: value === undefined ? undefined : {"content-type": "application/json"},
      body: value === undefined ? undefined : JSON.stringify(value),
    });
    const text = await response.text();
    let body = {value: null};
    if (text) {
      try {
        body = JSON.parse(text);
      } catch {
        fail(`invalid ${method} ${path} response: ${text}`);
      }
    }
    if (!response.ok || body.value?.error) fail(`${method} ${path}: ${body.value?.message ?? response.statusText}`);
    return body.value;
  }

  async status() {
    return this.request("/status");
  }

  async createSession() {
    const value = await this.request("/session", "POST", {capabilities: {alwaysMatch: {browserName: "safari"}}});
    if (!value?.sessionId || !value.capabilities) fail("session response has no id or capabilities");
    this.sessionId = value.sessionId;
    this.capabilities = value.capabilities;
    if (typeof this.capabilities.browserVersion !== "string" || !this.capabilities.browserVersion) fail("Safari browser version is unavailable");
  }

  async deleteSession() {
    if (!this.sessionId) return;
    const sessionId = this.sessionId;
    this.sessionId = null;
    await this.request(`/session/${sessionId}`, "DELETE");
  }

  path(suffix) {
    if (!this.sessionId) fail("session is not started");
    return `/session/${this.sessionId}${suffix}`;
  }

  async navigate(url) {
    await this.request(this.path("/url"), "POST", {url});
  }

  async execute(script, args = []) {
    return this.request(this.path("/execute/sync"), "POST", {script, args});
  }

  async find(selector) {
    const value = await this.request(this.path("/element"), "POST", {using: "css selector", value: selector});
    const id = value?.[elementKey];
    if (typeof id !== "string" || !id) fail(`missing element: ${selector}`);
    return id;
  }

  async click(elementId) {
    await this.request(this.path(`/element/${elementId}/click`), "POST", {});
  }

  async actions(actions) {
    await this.request(this.path("/actions"), "POST", {actions});
  }

  async releaseActions() {
    await this.request(this.path("/actions"), "DELETE");
  }

  async screenshot() {
    const value = await this.request(this.path("/screenshot"));
    if (typeof value !== "string" || !value) fail("empty screenshot");
    return value;
  }

  async wait(script, timeoutMs = 15000, description = "page readiness") {
    const deadline = Date.now() + timeoutMs;
    let lastError = null;
    while (Date.now() < deadline) {
      try {
        if (await this.execute(script)) return;
      } catch (error) {
        lastError = error;
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    fail(`timed out waiting for ${description}${lastError ? `: ${lastError.message}` : ""}`);
  }
}

function pageReady(renderer) {
  return `return Boolean(window.unpolishedPeas?.rendererDiagnostic) && window.unpolishedPeas.rendererDiagnostic.requested_renderer === ${JSON.stringify(renderer)};`;
}

async function capture(client, directory, game, renderer, driverStatus, captureProbe = null) {
  const page = await client.execute("const api = window.unpolishedPeas; const canvas = document.querySelector('canvas[data-unpolished-peas]'); const gl = api?.host?.context?.(); return {user_agent: navigator.userAgent, platform: navigator.platform, renderer: api?.renderer ?? null, diagnostic: api?.rendererDiagnostic ?? null, artifacts: api?.host?.artifacts?.() ?? [], storage: api?.host?.storage(), audio: api?.host?.audio(), lifecycle: api?.host?.lifecycle(), canvas: {width: canvas?.width, height: canvas?.height, drawing_buffer_width: gl?.drawingBufferWidth, drawing_buffer_height: gl?.drawingBufferHeight}};");
  const artifact = {
    schema_version: 1,
    game,
    browser: {name: "safari", version: client.capabilities.browserVersion, user_agent: page.user_agent, platform: page.platform, capabilities: client.capabilities},
    safaridriver: driverStatus,
    renderer,
    selected_renderer: page.renderer,
    diagnostic: page.diagnostic,
    artifacts: page.artifacts,
    storage: page.storage,
    audio: page.audio,
    lifecycle: page.lifecycle,
    canvas: page.canvas,
    capture_probe: captureProbe,
    screenshot: `screenshot-${renderer}.png`,
  };
  await writeFile(join(directory, `safari-${renderer}-artifacts.json`), JSON.stringify(artifact, null, 2) + "\n");
  const screenshot = await client.screenshot();
  await writeFile(join(directory, artifact.screenshot), Buffer.from(screenshot, "base64"));
  return artifact;
}

// Probe a blank page at the package's origin before loading Peas so unavailable
// runner canvas PNG export cannot be mistaken for a rendering regression.
function probeWebGlCapture() {
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 32;
  document.body.append(canvas);
  const gl = canvas.getContext("webgl2", {alpha: false, antialias: false, preserveDrawingBuffer: true});
  if (!gl) return {context_lost: true, error: null, pixel: [], png_capture_available: false};
  gl.clearColor(1, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  const pixel = new Uint8Array(4);
  gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
  const error = gl.getError();
  const capture = canvas.toDataURL("image/png");
  return {context_lost: gl.isContextLost(), error, pixel: Array.from(pixel), png_capture_available: capture.startsWith("data:image/png"), png_capture_result: capture.slice(0, 40)};
}

function webGlRenderContract() {
  const api = window.unpolishedPeas;
  const gl = api.host.context();
  const pack = (r, g, b) => (r | (g << 8) | (b << 16) | 0xff000000) >>> 0;
  const statuses = [
    api.runtime.up_browser_set_camera(0, 0, 0, 0, 0, 0, 0, 0, 0),
    api.runtime.up_browser_clear(pack(19, 37, 61)),
    api.runtime.up_browser_draw_rect(1, 1, 4, 3, pack(255, 0, 0)),
    api.runtime.up_browser_present(0),
  ];
  const pixel = new Uint8Array(4);
  gl.readPixels(2, gl.drawingBufferHeight - 3, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
  return {statuses, pixel: Array.from(pixel), error: gl.getError(), context_lost: gl.isContextLost()};
}

function validateWebGlReadback(result, label) {
  const detail = `${label}: ${JSON.stringify(result)}`;
  assert.equal(result.context_lost, false, detail);
  assert.equal(result.error, 0, detail);
  if (result.statuses) assert.ok(result.statuses.every((status) => status === 0), detail);
  assert.ok(Array.isArray(result.pixel) && result.pixel.length === 4 && result.pixel.every((value, index) => Math.abs(value - [255, 0, 0, 255][index]) <= 1), detail);
}

export function browserContract() {
  const api = window.unpolishedPeas;
  const audio = api.host.audio();
  const text = new TextEncoder().encode("safari webdriver");
  new Uint8Array(api.host.memory.buffer, 0, text.length).set(text);
  api.runtime.up_browser_diagnostic_emit(0, text.length);
  const artifacts = api.host.artifacts();
  const frame = api.host.captureFrame();
  return {
    storage: api.host.storage(),
    audio,
    runtime_audio_state: api.runtime.up_browser_audio_state(),
    frame_capture: frame?.startsWith("data:image/png") ?? false,
    frame_capture_result: frame?.slice(0, 40) ?? null,
    diagnostic_emitted: artifacts.some((artifact) => artifact.name === "diagnostics.json" && artifact.data.includes("safari webdriver")),
    renderer_diagnostic_matches: artifacts.find((artifact) => artifact.name === "renderer-diagnostics.json")?.data === JSON.stringify(api.rendererDiagnostic),
    lifecycle: api.host.lifecycle(),
  };
}

export function validateBrowserContract(contract, pngCaptureAvailable = true) {
  assert.equal(contract.storage?.phase, "ready", `Safari storage: ${JSON.stringify(contract.storage)}`);
  assert.equal(contract.runtime_audio_state, contract.audio?.state, `Safari audio: ${JSON.stringify(contract.audio)}`);
  assert.equal(typeof contract.audio?.phase, "string", "Safari audio phase is missing");
  if (pngCaptureAvailable) assert.equal(contract.frame_capture, true, "Safari frame capture did not return a PNG");
  else assert.ok(contract.frame_capture === true || contract.frame_capture_result === null, "unavailable Safari capture must return null rather than an invalid image");
  assert.equal(contract.diagnostic_emitted, true, "Safari diagnostic emission failed");
  assert.equal(contract.renderer_diagnostic_matches, true, "Safari renderer diagnostic artifact differs from the page diagnostic");
  assert.ok(contract.lifecycle?.scheduledFrames > 0, `Safari frame scheduling stopped: ${JSON.stringify(contract.lifecycle)}`);
}

async function smoke(client, game, renderer, directory, driverStatus, captureProbe) {
  await client.wait(pageReady(renderer));
  const diagnostic = await client.execute("return window.unpolishedPeas?.rendererDiagnostic ?? null;");
  const availability = validateRenderer(diagnostic, renderer);
  if (availability === "unavailable") {
    const artifact = await capture(client, directory, game, renderer, driverStatus, captureProbe);
    assert.equal(artifact.selected_renderer, null);
    return availability;
  }
  const canvas = await client.find("canvas[data-unpolished-peas]");
  assert.equal(await client.execute("return document.querySelector('canvas[data-unpolished-peas]')?.dataset.game ?? null;"), game);
  await client.click(canvas);
  await client.actions([
    {type: "pointer", id: "mouse", parameters: {pointerType: "mouse"}, actions: [{type: "pointerMove", origin: {[elementKey]: canvas}, x: 0, y: 0}, {type: "pointerDown", button: 0}]},
    {type: "key", id: "keyboard", actions: [{type: "keyDown", value: "w"}]},
  ]);
  const input = await client.execute("const input = window.unpolishedPeas?.host?.input(); return Boolean(window.unpolishedPeas?.runtime && input?.down[0] && input.pointerDown[0] && Number.isFinite(input.pointer.canvasX) && Number.isFinite(input.pointer.canvasY));");
  assert.equal(input, true);
  const blur = await client.execute("window.dispatchEvent(new Event('blur')); const input = window.unpolishedPeas.host.input(); return !input.down[0] && !input.pointerDown[0] && input.released[0] && input.pointerReleased[0];");
  assert.equal(blur, true);
  await client.releaseActions();
  if (renderer === "webgl2") {
    const rendered = await client.execute(`return (${webGlRenderContract.toString()})();`);
    await writeFile(join(directory, "webgl2-readback.json"), JSON.stringify(rendered, null, 2) + "\n");
    validateWebGlReadback(rendered, "Safari Peas WebGL pixel output");
  }
  const pngCaptureAvailable = captureProbe?.png_capture_available ?? true;
  if (pngCaptureAvailable) await client.wait("return Boolean(window.unpolishedPeas?.host?.captureFrame()?.startsWith('data:image/png'));", 15000, "a readable PNG frame");
  const contract = await client.execute(`return (${browserContract.toString()})();`);
  validateBrowserContract(contract, pngCaptureAvailable);
  const artifact = await capture(client, directory, game, renderer, driverStatus, captureProbe);
  assert.equal(artifact.selected_renderer, renderer);
  return availability;
}

async function main() {
  const [baseUrl, artifactDirectory] = process.argv.slice(2);
  if (!baseUrl || !artifactDirectory) fail("usage: safari_webdriver.mjs PACKAGE_URL ARTIFACT_DIRECTORY");
  await mkdir(artifactDirectory, {recursive: true});
  const game = process.env.UP_SAFARI_GAME ?? "bounce";
  const renderers = selectedRenderers(process.env.UP_SAFARI_RENDERERS);
  const client = new WebDriver(process.env.UP_SAFARI_WEBDRIVER_URL ?? "http://127.0.0.1:4444");
  const driverStatus = await client.status();
  try {
    await client.createSession();
    const unavailable = [];
    for (const renderer of renderers) {
      let captureProbe = null;
      try {
        if (renderer === "webgl2") {
          await client.navigate(`${baseUrl.replace(/\/$/, "")}/__peas-capture-probe__.html`);
          captureProbe = await client.execute(`return (${probeWebGlCapture.toString()})();`);
          await writeFile(join(artifactDirectory, "webgl2-capture-probe.json"), JSON.stringify(captureProbe, null, 2) + "\n");
          validateWebGlReadback(captureProbe, "Safari independent WebGL probe");
          if (!captureProbe.png_capture_available) console.log("::notice::Safari canvas PNG export is unavailable before Peas loads; requiring runtime pixel readback and retaining the WebDriver screenshot.");
        }
        await client.navigate(`${baseUrl}?renderer=${renderer}`);
        if (await smoke(client, game, renderer, artifactDirectory, driverStatus, captureProbe) === "unavailable") unavailable.push(renderer);
      } catch (error) {
        try {
          await capture(client, artifactDirectory, game, renderer, driverStatus, captureProbe);
        } catch (captureError) {
          console.error(`Safari failure artifact capture: ${captureError.message}`);
        }
        throw error;
      }
    }
    console.log(`Safari WebDriver smoke passed: forced-${renderers.join(", forced-")}${unavailable.length ? ` unavailable=${unavailable.join(",")}` : ""}`);
  } finally {
    await client.deleteSession();
  }
}

if (import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  main().catch((error) => {
    console.error(error.stack || error.message);
    if (/Allow remote automation|remote automation/i.test(error.message)) console.error("Safari WebDriver recovery: run `safaridriver --enable` once, then rerun this command.");
    process.exitCode = 1;
  });
}
