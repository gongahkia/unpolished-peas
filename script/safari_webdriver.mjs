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
    if (diagnostic.selected_renderer !== "webgl2" || diagnostic.fallback_reason !== null || diagnostic.capabilities?.webgl2 !== "available" || diagnostic.context_status !== "ready") fail("forced WebGL 2 was not selected")
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

  async wait(script, timeoutMs = 15000) {
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
    fail(`timed out waiting for page readiness${lastError ? `: ${lastError.message}` : ""}`);
  }
}

function pageReady(renderer) {
  return `return Boolean(window.unpolishedPeas?.rendererDiagnostic) && window.unpolishedPeas.rendererDiagnostic.requested_renderer === ${JSON.stringify(renderer)};`;
}

async function capture(client, directory, renderer, driverStatus) {
  const page = await client.execute("return {user_agent: navigator.userAgent, platform: navigator.platform, renderer: window.unpolishedPeas?.renderer ?? null, diagnostic: window.unpolishedPeas?.rendererDiagnostic ?? null, artifacts: window.unpolishedPeas?.host?.artifacts?.() ?? []};");
  const screenshot = await client.screenshot();
  const artifact = {
    schema_version: 1,
    browser: {name: "safari", version: client.capabilities.browserVersion, user_agent: page.user_agent, platform: page.platform, capabilities: client.capabilities},
    safaridriver: driverStatus,
    renderer,
    selected_renderer: page.renderer,
    diagnostic: page.diagnostic,
    artifacts: page.artifacts,
    screenshot: `screenshot-${renderer}.png`,
  };
  await writeFile(join(directory, `safari-${renderer}-artifacts.json`), JSON.stringify(artifact, null, 2) + "\n");
  await writeFile(join(directory, artifact.screenshot), Buffer.from(screenshot, "base64"));
  return artifact;
}

async function smoke(client, renderer, directory, driverStatus) {
  await client.wait(pageReady(renderer));
  const diagnostic = await client.execute("return window.unpolishedPeas?.rendererDiagnostic ?? null;");
  assert.equal(validateRenderer(diagnostic, renderer), "available");
  const canvas = await client.find("canvas[data-unpolished-peas]");
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
  const contract = await client.execute("const api = window.unpolishedPeas; const audio = api.host.audio(); const text = new TextEncoder().encode('safari webdriver'); new Uint8Array(api.host.memory.buffer, 0, text.length).set(text); api.runtime.up_browser_diagnostic_emit(0, text.length); const diagnosticArtifact = api.host.artifacts().find((artifact) => artifact.name === 'renderer-diagnostics.json'); return api.host.storage().phase === 'ready' && api.runtime.up_browser_audio_state() === audio.state && typeof audio.phase === 'string' && api.host.captureFrame().startsWith('data:image/png') && api.host.artifacts().some((artifact) => artifact.name === 'diagnostics.json' && artifact.data.includes('safari webdriver')) && diagnosticArtifact?.data === JSON.stringify(api.rendererDiagnostic) && api.host.lifecycle().scheduledFrames > 0;");
  assert.equal(contract, true);
  const artifact = await capture(client, directory, renderer, driverStatus);
  assert.equal(artifact.selected_renderer, renderer);
}

async function main() {
  const [baseUrl, artifactDirectory] = process.argv.slice(2);
  if (!baseUrl || !artifactDirectory) fail("usage: safari_webdriver.mjs PACKAGE_URL ARTIFACT_DIRECTORY");
  await mkdir(artifactDirectory, {recursive: true});
  const renderers = selectedRenderers(process.env.UP_SAFARI_RENDERERS);
  const client = new WebDriver(process.env.UP_SAFARI_WEBDRIVER_URL ?? "http://127.0.0.1:4444");
  const driverStatus = await client.status();
  try {
    await client.createSession();
    for (const renderer of renderers) {
      await client.navigate(`${baseUrl}?renderer=${renderer}`);
      await smoke(client, renderer, artifactDirectory, driverStatus);
    }
  } finally {
    await client.deleteSession();
  }
  console.log(`Safari WebDriver smoke passed: forced-${renderers.join(", forced-")}`);
}

if (import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  main().catch((error) => {
    console.error(error.stack || error.message);
    if (/Allow remote automation|remote automation/i.test(error.message)) console.error("Safari WebDriver recovery: run `safaridriver --enable` once, then rerun this command.");
    process.exitCode = 1;
  });
}
