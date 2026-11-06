import assert from "node:assert/strict";
import {createServer} from "node:http";
import {mkdir, readFile, writeFile} from "node:fs/promises";
import {resolve, join, extname, sep} from "node:path";
import {parseArgs} from "node:util";
import {adapter, prerequisiteFailure} from "./adapters.mjs";
import {instrumentation} from "./instrumentation.mjs";
import {probeWebGlCapture, webGlRenderContract, validateWebGlReadback, validateRenderer} from "../safari_webdriver.mjs";
import {portableChecks} from "../browser_portable_conformance_checks.mjs";
import {fontChecks} from "../browser_font_layout_checks.mjs";
import {audioChecks} from "../browser_audio_lifetime_checks.mjs";

const {values} = parseArgs({options: {
  consumer: {type: "string"}, font: {type: "string"}, audio: {type: "string"}, references: {type: "string"},
  browsers: {type: "string", default: "chromium,firefox,safari"}, diagnostics: {type: "string", default: "zig-out/diagnostics/browser-authoring"},
}});
const browsers = values.browsers.split(",");
assert.ok(browsers.length && new Set(browsers).size === browsers.length && browsers.every((name) => ["chromium", "firefox", "safari"].includes(name)), "select chromium,firefox,safari without duplicates");
const cases = Object.entries({consumer: portableChecks, font: fontChecks, audio: audioChecks}).filter(([name]) => values[name]);
assert.ok(cases.length, "supply at least one --consumer, --font or --audio bundle");
if (values.font) assert.ok(values.references, "--font requires native --references");
const directory = resolve(values.diagnostics);
await mkdir(directory, {recursive: true});
const report = {schema_version: 1, requested_browsers: browsers, platform: process.platform, architecture: process.arch, node: process.version, renderer: "webgl2", results: []};
const persist = () => writeFile(join(directory, "result.json"), JSON.stringify(report, null, 2) + "\n");
const mime = {".html": "text/html; charset=utf-8", ".mjs": "application/javascript", ".js": "application/javascript", ".wasm": "application/wasm", ".json": "application/json", ".png": "image/png"};
const server = createServer(async (request, response) => {
  try {
    const path = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    if (path === "/__peas-capture-probe__.html") {
      response.writeHead(200, {"content-type": mime[".html"]}); response.end("<!doctype html><html><body></body></html>"); return;
    }
    const [, mount, ...rest] = path.split("/");
    if (!values[mount] || !cases.some(([name]) => name === mount)) throw new Error("unknown mount");
    const root = resolve(values[mount]);
    const file = resolve(root, rest.join("/") || "index.html");
    if (!file.startsWith(root + sep)) throw new Error("path outside bundle");
    let data = await readFile(file);
    // Test-only observability. Files in the built bundle remain untouched.
    if (extname(file) === ".html") data = Buffer.from(data.toString().replace(/<script\b/, "<script>(" + instrumentation.toString() + ")();</script><script"));
    response.writeHead(200, {"content-type": mime[extname(file)] ?? "application/octet-stream", "cache-control": "no-store"});
    response.end(data);
  } catch { response.writeHead(404); response.end("not found"); }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const base = "http://127.0.0.1:" + server.address().port;
const json = (path, value) => writeFile(path, JSON.stringify(value, null, 2) + "\n");

async function state(driver) {
  return driver.evaluate(() => {
    const api = window.unpolishedPeas;
    return {url: location.href, user_agent: navigator.userAgent, platform: navigator.platform, renderer: api?.renderer, diagnostic: api?.rendererDiagnostic, storage: api?.host?.storage(), audio: api?.host?.audio(), input: api?.host?.input(), lifecycle: api?.host?.lifecycle(), instrumentation: window.peasTest, artifacts: api?.host?.artifacts()};
  });
}

async function runCase(browser, name, checks) {
  const output = join(directory, browser, name);
  await mkdir(output, {recursive: true});
  const result = {case: name, status: "unverified", artifacts: output};
  const driver = adapter(browser);
  let opened = false;
  const timeout = setTimeout(() => driver.close().catch(() => {}), 150000);
  try {
    try { await driver.open(); opened = true; }
    catch (error) { result.status = prerequisiteFailure(error) ? "unverified" : "failed"; throw error; }
    result.version = driver.version;
    if (driver.client) result.webdriver_capabilities = driver.client.capabilities;
    await driver.navigate(base + "/__peas-capture-probe__.html");
    driver.captureProbe = await driver.evaluate(probeWebGlCapture);
    await json(join(output, "independent-capture-probe.json"), driver.captureProbe);
    validateWebGlReadback(driver.captureProbe, "independent WebGL probe");
    assert.ok(driver.captureProbe.png_capture_available || browser === "safari", "only independently unavailable Safari PNG may use nullable capture");
    result.status = "failed"; // Once the prerequisites work, assertion failures are regressions.
    await driver.navigate(base + "/" + name + "/?renderer=webgl2");
    await driver.wait(() => Boolean(window.unpolishedPeas?.rendererDiagnostic), null, "renderer diagnostic");
    const diagnostic = await driver.evaluate(() => window.unpolishedPeas.rendererDiagnostic);
    result.renderer_diagnostic = diagnostic;
    if (browser === "safari") validateRenderer(diagnostic, "webgl2");
    assert.equal(diagnostic.requested_renderer, "webgl2");
    assert.equal(diagnostic.selected_renderer, "webgl2");
    assert.equal(diagnostic.capabilities.webgl2, "available");
    assert.equal(diagnostic.context_status, "ready");
    assert.equal(diagnostic.fallback_reason, null);
    await driver.wait(() => document.querySelector('[role="status"]')?.dataset.state === "ready", null, "host readiness");
    const readback = await driver.evaluate(webGlRenderContract);
    await json(join(output, "runtime-webgl-readback.json"), readback);
    validateWebGlReadback(readback, "Peas WebGL renderer");
    result.observations = await checks(driver, {directory: output, references: values.references && resolve(values.references)});
    const environment = await state(driver);
    await json(join(output, "environment.json"), environment);
    assert.deepEqual(environment.instrumentation.errors, [], "browser JavaScript errors");
    assert.equal(environment.instrumentation.invalidPcm, 0, "nonfinite PCM submission");
    result.user_agent = environment.user_agent;
    result.status = "passed";
  } catch (error) {
    result.error = error.stack ?? String(error);
    await writeFile(join(output, "failure.log"), result.error + "\n");
    if (opened) {
      try { await json(join(output, "failure-environment.json"), await state(driver)); } catch (capture) { result.state_capture_error = capture.message; }
      try { await driver.screenshot(join(output, "failure.png")); } catch (capture) { result.screenshot_error = capture.message; }
    }
  } finally {
    clearTimeout(timeout);
    if (driver.console) await json(join(output, "console.json"), driver.console);
    try { await driver.close(); } catch (error) { result.cleanup_error = error.message; if (result.status === "passed") result.status = "failed"; }
  }
  await json(join(output, "result.json"), result);
  return result;
}

try {
  await persist();
  for (const browser of browsers) {
    const row = {browser, status: "unverified", cases: []};
    report.results.push(row);
    for (const [name, checks] of cases) {
      const result = await runCase(browser, name, checks);
      row.cases.push(result);
      console.log(browser + " " + name + ": " + result.status + (result.error ? " — " + result.error.split("\n")[0] : ""));
      await persist();
    }
    row.status = row.cases.some((value) => value.status === "failed") ? "failed" : row.cases.every((value) => value.status === "passed") ? "passed" : "unverified";
    await persist();
  }
  report.passed = report.results.every((value) => value.status === "passed");
  await persist();
  process.exitCode = report.passed ? 0 : report.results.some((value) => value.status === "failed") ? 1 : 69;
  console.log("Authoring browser evidence: " + join(directory, "result.json"));
} finally {
  await new Promise((resolve) => server.close(resolve));
}
