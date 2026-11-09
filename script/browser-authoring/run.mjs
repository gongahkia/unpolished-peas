import assert from "node:assert/strict";
import {createServer} from "node:http";
import {mkdir, readFile, writeFile} from "node:fs/promises";
import {resolve, join, extname, sep} from "node:path";
import {parseArgs} from "node:util";
import {spawn, execFile} from "node:child_process";
import {promisify} from "node:util";
import {fileURLToPath} from "node:url";
import {createWriteStream} from "node:fs";
import {createServer as createSocketServer} from "node:net";
import {once} from "node:events";
import {createHash} from "node:crypto";
import {adapter, prerequisiteFailure, sleep} from "./adapters.mjs";
import {validateLoggingArtifacts} from "./checks.mjs";
import {instrumentation} from "./instrumentation.mjs";
import {probeWebGlCapture, webGlRenderContract, validateWebGlReadback, validateRenderer} from "../safari_webdriver.mjs";
import {portableChecks} from "../browser_portable_conformance_checks.mjs";
import {fontChecks} from "../browser_font_layout_checks.mjs";
import {audioChecks} from "../browser_audio_lifetime_checks.mjs";
import {surfaceChecks} from "../browser_surface_gpu_checks.mjs";

const {values} = parseArgs({options: {
  consumer: {type: "string"}, font: {type: "string"}, audio: {type: "string"}, references: {type: "string"},
  surface: {type: "string"}, "surface-references": {type: "string"}, logging: {type: "boolean", default: false},
  browsers: {type: "string", default: "chromium,firefox,safari"}, diagnostics: {type: "string", default: "zig-out/diagnostics/browser-authoring"},
}});
const browsers = values.browsers.split(",");
assert.ok(browsers.length && new Set(browsers).size === browsers.length && browsers.every((name) => ["chromium", "firefox", "safari"].includes(name)), "select chromium,firefox,safari without duplicates");
const cases = Object.entries({consumer: portableChecks, font: fontChecks, audio: audioChecks, surface: surfaceChecks}).filter(([name]) => values[name]);
assert.ok(cases.length, "supply at least one --consumer, --font, --audio or --surface bundle");
if (values.font) assert.ok(values.references, "--font requires native --references");
if (values.surface) assert.ok(values["surface-references"], "--surface requires CPU --surface-references");
const directory = resolve(values.diagnostics);
await mkdir(directory, {recursive: true});
const report = {schema_version: 1, requested_browsers: browsers, platform: process.platform, architecture: process.arch, node: process.version, renderer: "webgl2", results: []};
report.harness_sha256 = {};
for (const file of ["run.mjs", "adapters.mjs", "checks.mjs", "instrumentation.mjs", "package.json", "package-lock.json", "../safari_webdriver.mjs", "../browser_portable_conformance_checks.mjs", "../browser_font_layout_checks.mjs", "../browser_audio_lifetime_checks.mjs", "../browser_surface_gpu_checks.mjs"]) {
  report.harness_sha256[file] = createHash("sha256").update(await readFile(new URL(file, import.meta.url))).digest("hex");
}
let surfaceReferences;
if (values.surface) {
  surfaceReferences = join(directory, "surface-reference");
  await mkdir(surfaceReferences, {recursive: true});
  report.surface_reference_sha256 = {};
  for (const file of ["surface.json", ...Array.from({length: 12}, (_, i) => `surface-${i}.rgba`)]) {
    const bytes = await readFile(join(resolve(values["surface-references"]), file));
    await writeFile(join(surfaceReferences, file), bytes);
    report.surface_reference_sha256[file] = createHash("sha256").update(bytes).digest("hex");
  }
}
let references;
if (values.font) {
  references = join(directory, "native-reference");
  await mkdir(references, {recursive: true});
  report.reference_sha256 = {};
  for (const file of ["font.json", "font-initial.rgba", "font-selected.rgba", "font-dialogue.rgba"]) {
    const bytes = await readFile(join(resolve(values.references), file));
    await writeFile(join(references, file), bytes);
    report.reference_sha256[file] = createHash("sha256").update(bytes).digest("hex");
  }
}
const persist = () => writeFile(join(directory, "result.json"), JSON.stringify(report, null, 2) + "\n");
const mime = {".html": "text/html; charset=utf-8", ".mjs": "application/javascript", ".js": "application/javascript", ".wasm": "application/wasm", ".json": "application/json", ".png": "image/png"};
const httpLog = createWriteStream(join(directory, "http.log"));
const server = createServer(async (request, response) => {
  response.on("finish", () => httpLog.write(JSON.stringify({path: request.url, status: response.statusCode}) + "\n"));
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

async function safariService() {
  if (!browsers.includes("safari") || process.env.UP_SAFARI_WEBDRIVER_URL) return async () => {};
  try {
    const value = await fetch("http://127.0.0.1:4444/status", {signal: AbortSignal.timeout(1000)}).then((response) => response.json());
    if (typeof value.value?.ready === "boolean") return async () => {};
  } catch {}
  const socket = createSocketServer();
  await new Promise((resolve) => socket.listen(0, "127.0.0.1", resolve));
  const port = socket.address().port;
  await new Promise((resolve) => socket.close(resolve));
  const url = "http://127.0.0.1:" + port;
  process.env.UP_SAFARI_WEBDRIVER_URL = url;
  const log = createWriteStream(join(directory, "safaridriver.log"));
  const child = spawn("safaridriver", ["-p", String(port), "--diagnose"], {stdio: ["ignore", "pipe", "pipe"]});
  child.stdout.pipe(log, {end: false}); child.stderr.pipe(log, {end: false});
  let failed = false;
  child.on("error", (error) => { failed = true; log.write(error.stack + "\n"); });
  for (let i = 0; i < 30 && !failed; i += 1) {
    try {
      const response = await fetch(url + "/status", {signal: AbortSignal.timeout(1000)});
      if (response.ok) break;
    } catch {}
    await sleep(100);
  }
  return async () => {
    if (child.pid && child.exitCode === null && child.signalCode === null) {
      const exited = once(child, "exit");
      child.kill("SIGTERM");
      await Promise.race([exited, sleep(5000)]);
    }
    log.end();
  };
}

async function state(driver) {
  return driver.evaluate(() => {
    const api = window.unpolishedPeas;
    return {focus: {document: document.hasFocus(), active: document.activeElement?.tagName, visibility: document.visibilityState}, url: location.href, user_agent: navigator.userAgent, platform: navigator.platform, renderer: api?.renderer, diagnostic: api?.rendererDiagnostic, storage: api?.host?.storage(), audio: api?.host?.audio(), input: api?.host?.input(), lifecycle: api?.host?.lifecycle(), instrumentation: window.peasTest, artifacts: api?.host?.artifacts()};
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
    await driver.navigate(base + "/" + name + "/?renderer=webgl2" + (values.logging ? "&peas-log=debug" : ""));
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
    result.observations = await checks(driver, {directory: output, references: name === "surface" ? surfaceReferences : references});
    if (values.logging) {
      if (name === "consumer") {
        const failures = await driver.evaluate(() => {
          const {runtime, host} = window.unpolishedPeas;
          const statuses = [];
          for (let i = 0; i < 6; i += 1) {
            runtime.conformance_reject_next_init();
            statuses.push(runtime.up_browser_init(320, 160));
            if (host.lifecycle().scheduledFrames !== 0 || host.resourceCount() !== 0) throw new Error("failed init leaked resources or callbacks");
          }
          return statuses;
        });
        assert.deepEqual(failures, Array(6).fill(-3));
      }
      const artifacts = await driver.evaluate(() => window.unpolishedPeas.host.artifacts());
      result.logging = validateLoggingArtifacts(artifacts, name === "consumer" ? "ConformanceInitRejected" : null);
      const artifactsDirectory = join(output, "runtime-artifacts", String(result.logging.session_id));
      result.logging.artifacts = artifactsDirectory;
      await mkdir(artifactsDirectory, {recursive: true});
      for (const artifact of artifacts) {
        assert.ok(/^[a-zA-Z0-9_.-]+$/.test(artifact.name), "artifact filename cannot escape its directory");
        const bytes = artifact.type === "image/png" ? Buffer.from(artifact.data.split(",")[1], "base64") : artifact.data;
        if (artifact.type === "image/png") assert.ok(bytes.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])), "exported PNG must have a real signature");
        await writeFile(join(artifactsDirectory, artifact.name), bytes);
      }
    }
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
    if (result.status === "passed" && result.logging?.artifacts) {
      try {
        const bundle = join(output, "support", String(result.logging.session_id));
        const {stdout, stderr} = await promisify(execFile)("zig", ["build", "peas", "--", "--json", "--non-interactive", "support-bundle", result.logging.artifacts, bundle], {cwd: fileURLToPath(new URL("../../", import.meta.url)), timeout: 120000, maxBuffer: 8 * 1024 * 1024});
        assert.equal(JSON.parse(stdout).status, "ok");
        const manifest = JSON.parse(await readFile(join(bundle, "support-bundle.json"), "utf8"));
        assert.ok(manifest.artifacts.includes("events.jsonl") && manifest.artifacts.includes("logging.json"));
        if (name === "consumer") assert.equal(manifest.artifacts.filter((file) => file.startsWith("incident-")).length, 4);
        result.logging.support_bundle = bundle;
        await writeFile(join(output, "support-export.log"), stderr);
      } catch (error) {
        result.status = "failed";
        result.support_export_error = error.stack ?? String(error);
      }
    }
  }
  await json(join(output, "result.json"), result);
  return result;
}

const closeSafariService = await safariService();
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
  await closeSafariService();
  await new Promise((resolve) => server.close(resolve));
  httpLog.end();
}
