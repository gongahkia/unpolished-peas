// Complete GameProtocol frames, reusing the installed browser adapter/readback
// and the engine's existing native timing reporter. No CDP profiling required.
import assert from "node:assert/strict";
import {createServer} from "node:http";
import {readFile, writeFile, mkdir} from "node:fs/promises";
import {execFileSync, spawnSync} from "node:child_process";
import {resolve, join, extname, sep} from "node:path";
import {parseArgs} from "node:util";
import {createHash} from "node:crypto";
import {gzipSync} from "node:zlib";
import os from "node:os";
import {PlaywrightAdapter} from "./browser-authoring/adapters.mjs";
import {readFrame} from "./browser-authoring/checks.mjs";

const {values} = parseArgs({options: {
  bundle: {type: "string", default: "zig-out/render-capacity"},
  output: {type: "string", default: "zig-out/diagnostics/render-capacity"},
  "verify-only": {type: "boolean", default: false},
  rounds: {type: "string", default: "3"},
  modes: {type: "string", default: "cpu"},
}});
const modes = values.modes.split(",");
assert.ok(modes.length && new Set(modes).size === modes.length && modes.every(mode => ["cpu", "gpu"].includes(mode)));
const verify = values["verify-only"];
const rounds = verify ? 1 : Number(values.rounds);
assert.ok(Number.isInteger(rounds) && rounds >= 1 && rounds <= 10);
const warmup = verify ? 4 : 120, measured = verify ? 8 : 240;
const total = warmup + measured;
const bundle = resolve(values.bundle), output = resolve(values.output);
const executable = (name) => join(bundle, name + (process.platform === "win32" ? ".exe" : ""));
const build = JSON.parse(await readFile(join(bundle, "build.json"), "utf8"));
if (!verify) {
  assert.equal(build.native_optimize, "ReleaseFast", "measure native ReleaseFast");
  assert.equal(build.wasm_optimize, "ReleaseFast", "measure Wasm ReleaseFast");
}
await mkdir(output, {recursive: true});
const baseCases = [{width: 320, linear: false}, {width: 640, linear: false}, {width: 1280, linear: false}, {width: 1280, linear: true}].map((c) => ({...c, height: c.width * 9 / 16, id: `${c.width}-${c.linear ? "linear" : "nearest"}`}));
const cases = baseCases.flatMap(c => modes.map(mode => ({...c, mode, executable_id: c.id, id: modes.length === 1 && mode === "cpu" ? c.id : `${mode}-${c.id}`})));
const orderedCases = round => round % 2 === 0 ? cases.toReversed() : cases;
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
function command(program, args) {
  try { return execFileSync(program, args, {encoding: "utf8", timeout: 30000}).trim(); }
  catch (error) { return {unavailable: error.message}; }
}
// Nearest-rank quantiles, no timing budgets or hardware-specific pass criteria.
function distribution(samples) {
  assert.ok(samples.length && samples.every((v) => Number.isFinite(v) && v >= 0));
  const sorted = samples.toSorted((a, b) => a - b);
  const percentile = (p) => sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)];
  return {samples: sorted.length, min_ms: sorted[0], median_ms: percentile(.5), p95_ms: percentile(.95), p99_ms: percentile(.99), max_ms: sorted.at(-1), mean_ms: sorted.reduce((a, b) => a + b, 0) / sorted.length};
}
const report = {
  schema: "game-render-capacity-v2", date: new Date().toISOString(), mode: verify ? "correctness" : "measurement", render_modes: modes,
  order: "serial native then Chromium; paired CPU/GPU cases, reversed on even rounds",
  warmup_frames: warmup, measured_frames: measured, rounds, quantiles: "nearest rank",
  workload: {sprites: 1000, sprite_size: [16, 16], opaque_fraction: .75, translucent_fraction: .25, labels: 12, text: "Willow iii WWW — Zoë\nFind the lantern by the bridge.", font: "Source Sans 3 Regular", font_height: 14, world: [320, 180], overlay: [160, 90], overlay_rectangles: 64, output_window: [1280, 720], native_high_dpi: true, fixed_hz: 60},
  machine: {hostname: os.hostname(), platform: os.platform(), release: os.release(), architecture: os.arch(), cpu: os.cpus()[0]?.model, logical_cpus: os.cpus().length, memory_bytes: os.totalmem(), node: process.version, zig: command("zig", ["version"])},
  checkout: {head: command("git", ["rev-parse", "HEAD"]), status: command("git", ["status", "--short"]), diff_sha256: sha(command("git", ["diff"]))},
  source_sha256: {}, binaries_sha256: {}, results: [], status: "running",
  build,
  unavailable_metrics: ["GPU completion time (no fences/timer queries in timed frames)", "actual display scanout/pacing", "SDL/driver and JavaScript allocation events", "native upload separately from presentation/driver waits"],
};
if (process.platform === "darwin") {
  report.machine.graphics = command("system_profiler", ["SPDisplaysDataType"]);
  report.machine.power_before = command("pmset", ["-g", "batt"]);
}
for (const path of ["examples/render_capacity_game.zig", "examples/render_capacity.zig", "examples/render_capacity_reference.zig", "src/render_capacity_build.zig", "src/render_benchmark.zig", "src/canvas.zig", "src/backend/sdl_gpu.zig", "src/browser/runtime.zig", "src/browser/host.mjs", "script/benchmark_game_rendering.mjs", "script/browser-authoring/adapters.mjs", "script/browser-authoring/checks.mjs", "script/browser-authoring/package-lock.json"]) report.source_sha256[path] = sha(await readFile(path));
for (const file of ["reference", ...baseCases.map((c) => "native-" + c.id)]) report.binaries_sha256[file] = sha(await readFile(executable(file)));
for (const path of ["src/surface_compositor.zig", "src/backend/surface_gpu.zig", "src/browser/surface_cache.zig", "src/browser/contract.zig", "shaders/surface.frag", "shaders/surface.frag.spv", "shaders/surface.frag.msl", "shaders/surface.frag.hlsl"]) report.source_sha256[path] = sha(await readFile(path));
report.binaries_sha256["web/unpolished-peas.wasm"] = sha(await readFile(join(bundle, "web/unpolished-peas.wasm")));
const persist = () => writeFile(join(output, "result.json"), JSON.stringify(report, null, 2) + "\n");
await persist();
const raw = [];
function summarize(platform, c, round, game, host) {
  assert.equal(game.length, total, `${platform} incomplete game sample capture`);
  assert.equal(host.length, total, `${platform} incomplete host sample capture`);
  assert.ok(game.every((v) => v.allocation_events === 0 && v.allocated_bytes === 0), `${platform} game allocated during update/draw`);
  const result = {platform, case: c.id, render_mode: c.mode, width: c.width, height: c.height, linear: c.linear, round, game_allocation_events: 0, game_allocated_bytes: 0, stages: {}};
  result.expected_texture_upload_bytes_per_frame = c.width * c.height * 4 + (c.mode === "gpu" ? (320 * 180 + 160 * 90) * 4 : 0);
  result.upload_byte_evidence = platform === "native" ? "calculated from fixed full-source uploads; excludes vertex buffers and driver staging" : "observed host import arguments; excludes vertex buffers and driver staging";
  if (platform === "chromium-webgl2") assert.ok(host.every(frame => frame.upload_bytes === result.expected_texture_upload_bytes_per_frame && frame.upload_calls === (c.mode === "gpu" ? 3 : 1)), "every texture source must upload exactly once per frame");
  for (const key of ["update_ms", "draw_ms", "sprites_ms", "text_ms", "composition_ms"]) result.stages[key] = distribution(game.slice(warmup).map((v) => v[key]));
  for (const key of Object.keys(host[0]).filter((key) => key.endsWith("_ms"))) result.stages[key] = distribution(host.slice(warmup).map((v) => v[key]));
  result.fixed_updates = game.slice(warmup).reduce((sum, value) => sum + value.updates, 0);
  raw.push({platform, case: c.id, round, game, host});
  report.results.push(result);
  console.log(`${platform} ${c.id} round=${round} draw median=${result.stages.draw_ms.median_ms.toFixed(3)}ms p95=${result.stages.draw_ms.p95_ms.toFixed(3)}ms frame median=${result.stages.frame_ms.median_ms.toFixed(3)}ms`);
  return result;
}
function tagged(log, tag) {
  const line = log.split("\n").find((line) => line.startsWith(tag + " "));
  assert.ok(line, `missing ${tag} evidence`);
  return JSON.parse(line.slice(tag.length + 1));
}
// Build everything first. Timed native processes and browser runs are serial;
// pixel-reference generation, captures, serialization and compression are not
// inside any measured interval. No new performance thresholds enter CI.
let server, driver;
try {
  for (let round = 1; round <= rounds; round += 1) for (const c of orderedCases(round)) {
    const path = executable("native-" + c.executable_id);
    const child = spawnSync(path, ["--frames", String(total)], {env: {...process.env, PEAS_RENDER_GPU: c.mode === "gpu" ? "1" : "0", UP_NATIVE_TIMING_SAMPLES: "1", UP_NATIVE_TIMING_REPORT: "1", UP_DEVELOPER_TOOLS: "0"}, encoding: "utf8", timeout: 120000, maxBuffer: 8 * 1024 * 1024});
    const log = (child.stdout ?? "") + (child.stderr ?? "");
    await writeFile(join(output, `native-${c.id}-${round}.log`), log);
    assert.equal(child.status, 0, `native ${c.id}: ${child.error ?? log.slice(-2000)}`);
    const game = tagged(log, "peas-game-samples"), host = tagged(log, "peas-host-samples");
    assert.equal(game.dropped, 0); assert.equal(host.dropped, 0);
    // This ordinary Canvas-only workload has one upload pass and, only when
    // a swapchain texture exists, one final presentation blit. No advanced
    // queues or capture passes can inflate this count.
    assert.ok(host.frames.slice(warmup).every((frame) => frame.pass_count === (c.mode === "gpu" ? 3 : 2)), "native composition/presentation pass unavailable; keep the window visible and rerun");
    const stageNames = {frame_ns: "frame_ms", interval_ns: "interval_ms", update_ns: "host_update_ms", draw_ns: "host_draw_ms", present_ns: "upload_present_ms"};
    const result = summarize("native", c, round, game.samples, host.frames.map((frame) => Object.fromEntries(Object.entries(frame).map(([key, value]) => [stageNames[key] ?? key, key.endsWith("_ns") ? value / 1e6 : value]))));
    result.framebuffer = host.framebuffer;
    result.renderer = log.split("\n").find((line) => line.includes("native renderer:"));
    result.presented_frames_verified = true;
    await persist();
  }
  // Exact native CPU references are produced after native measurements.
  for (const c of cases) {
    const reference = join(output, `${c.id}-native.rgba`);
    execFileSync(executable("reference"), [String(c.width), String(c.height), String(Number(c.linear)), reference, ...(c.mode === "gpu" ? ["gpu"] : [])], {timeout: 20000});
    c.reference = reference;
  }
  for (const c of cases.filter(c => c.mode === "gpu")) {
    c.original_reference = cases.find(other => other.mode === "cpu" && other.executable_id === c.executable_id)?.reference ?? join(output, `${c.executable_id}-original-cpu.rgba`);
    if (!modes.includes("cpu")) execFileSync(executable("reference"), [String(c.width), String(c.height), String(Number(c.linear)), c.original_reference], {timeout: 20000});
  }
  const web = join(bundle, "web");
  server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url, "http://localhost");
      if (url.pathname === "/") {
        const c = cases.find((c) => c.id === url.searchParams.get("case"));
        assert.ok(c);
        const configuration = {total, warmup, linear: c.linear, gpu: c.mode === "gpu", framebuffer: report.results[0].framebuffer};
        const html = `<!doctype html><meta charset="utf-8"><link rel="icon" href="data:,"><style>body{margin:0}canvas{width:1280px;height:720px;display:block}</style><canvas data-unpolished-peas width="${c.width}" height="${c.height}" tabindex="0"></canvas><script>(${instrumentation.toString()})(${JSON.stringify(configuration)})</script><script type="module" src="./bootstrap.mjs"></script>`;
        response.writeHead(200, {"content-type": "text/html; charset=utf-8"}); response.end(html); return;
      }
      const path = resolve(web, "." + decodeURIComponent(url.pathname));
      assert.ok(path.startsWith(web + sep));
      const bytes = await readFile(path);
      response.writeHead(200, {"content-type": {".mjs": "application/javascript", ".wasm": "application/wasm", ".json": "application/json"}[extname(path)] ?? "application/octet-stream", "cache-control": "no-store"});
      response.end(bytes);
    } catch { response.writeHead(404); response.end("not found"); }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  driver = new PlaywrightAdapter("chromium");
  await driver.open();
  // Match the native Retina framebuffer when running on this host; retain
  // observed backing sizes in every result instead of assuming CSS pixels.
  await driver.context.close();
  const nativeSize = report.results[0].framebuffer;
  const deviceScaleFactor = nativeSize.x / 1280;
  assert.equal(nativeSize.y / 720, deviceScaleFactor);
  driver.context = await driver.browser.newContext({viewport: {width: 1280, height: 720}, deviceScaleFactor});
  driver.page = await driver.context.newPage();
  driver.page.on("console", (message) => driver.console.push({type: message.type(), text: message.text()}));
  driver.page.on("pageerror", (error) => driver.console.push({type: "pageerror", text: error.stack}));
  report.browser_version = driver.version;
  for (let round = 1; round <= rounds; round += 1) for (const c of orderedCases(round)) {
    await driver.navigate(`http://127.0.0.1:${server.address().port}/?case=${c.id}&renderer=webgl2`);
    await driver.wait(() => window.capacity?.done, null, `${c.id} measured frames`, 120000);
    const evidence = await driver.evaluate(() => {
      const api = window.unpolishedPeas, runtime = api.runtime, state = window.capacity, gl = api.host.context();
      const debug = gl.getExtension("WEBGL_debug_renderer_info");
      const game = new Float64Array(api.host.imports.env.memory.buffer, runtime.peas_capacity_samples(), runtime.peas_capacity_count() * 8);
      const keys = ["update_ms", "draw_ms", "sprites_ms", "text_ms", "composition_ms", "allocation_events", "allocated_bytes", "updates"];
      const samples = Array.from({length: game.length / 8}, (_, i) => Object.fromEntries(keys.map((key, k) => [key, game[i * 8 + k]])));
      return {game: samples, host: Array.from({length: state.count}, (_, i) => ({frame_ms: state.frames[i * 8], interval_ms: state.frames[i * 8 + 1], upload_ms: state.frames[i * 8 + 2], present_ms: state.frames[i * 8 + 3], raf_timestamp_interval_ms: state.frames[i * 8 + 4], surface_submit_ms: state.frames[i * 8 + 5], upload_bytes: state.frames[i * 8 + 6], upload_calls: state.frames[i * 8 + 7]})), dropped: runtime.peas_capacity_dropped(), warmup_memory_bytes: state.warmupMemory, final_memory_bytes: api.host.imports.env.memory.buffer.byteLength, warmup_resource_count: state.warmupResources, final_resource_count: api.host.resourceCount(), framebuffer: {x: gl.drawingBufferWidth, y: gl.drawingBufferHeight}, renderer: {selected: api.renderer, version: gl.getParameter(gl.VERSION), vendor: debug ? gl.getParameter(debug.UNMASKED_VENDOR_WEBGL) : null, renderer: debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER)}, user_agent: navigator.userAgent, visibility: document.visibilityState, protocol_failure: runtime.up_browser_protocol_failure_phase(), render_status: runtime.up_browser_canvas_render_status()};
    });
    evidence.clock_min_tick_ms = await driver.evaluate(() => {
      let previous = performance.now(), smallest = Infinity;
      for (let i = 0; i < 10000; i += 1) {
        const now = performance.now();
        if (now > previous) smallest = Math.min(smallest, now - previous);
        previous = now;
      }
      return Number.isFinite(smallest) ? smallest : null;
    });
    assert.equal(evidence.dropped, 0); assert.equal(evidence.protocol_failure, -1); assert.equal(evidence.render_status, 0);
    assert.equal(evidence.visibility, "visible"); assert.equal(evidence.renderer.selected, "webgl2");
    assert.deepEqual(evidence.framebuffer, nativeSize, "native/browser output framebuffer sizes differ");
    const result = summarize("chromium-webgl2", c, round, evidence.game, evidence.host);
    const {game, host, ...metadata} = evidence;
    result.metadata = metadata;
    // Freeze the same deterministic tick, then draw through the actual runtime
    // and host. Sampling and GPU readback are entirely outside timed frames.
    await driver.evaluate(() => {
      const runtime = window.unpolishedPeas.runtime;
      runtime.peas_capacity_freeze(37);
      runtime.up_browser_frame(performance.now());
    });
    const frame = await driver.evaluate(readFrame, {width: c.width, height: c.height});
    assert.equal(frame.error, 0); assert.equal(frame.contextLost, false);
    const pixels = Buffer.from(frame.rgba), reference = await readFile(c.reference);
    await writeFile(join(output, `${c.id}-chromium-${round}.rgba`), pixels);
    if (frame.png) await writeFile(join(output, `${c.id}-chromium-${round}.png`), Buffer.from(frame.png.split(",")[1], "base64"));
    let maximum = 0, differences = 0;
    assert.equal(pixels.length, reference.length);
    for (let i = 0; i < pixels.length; i += 1) {
      const delta = Math.abs(pixels[i] - reference[i]);
      maximum = Math.max(maximum, delta); if (delta) differences += 1;
      if (i % 4 === 3) assert.equal(pixels[i], 255, "composition final alpha is opaque");
    }
    result.reference_comparison = {maximum_channel_delta: maximum, differing_channels: differences, tolerance: c.mode === "gpu" ? 6 : 0};
    assert.ok(maximum <= result.reference_comparison.tolerance, `${c.id} native/Wasm/WebGL pixels differ (max=${maximum}); inspect retained RGBA files`);
    result.exact_native_webgl_pixels = maximum === 0;
    if (c.mode === "gpu") {
      const original = await readFile(c.original_reference);
      let originalMaximum = 0, originalDifferences = 0;
      for (let i = 0; i < pixels.length; i += 1) {
        const delta = Math.abs(pixels[i] - original[i]);
        originalMaximum = Math.max(originalMaximum, delta);
        if (delta) originalDifferences += 1;
      }
      result.original_cpu_comparison = {maximum_channel_delta: originalMaximum, differing_channels: originalDifferences, tolerance: 6};
      assert.ok(originalMaximum <= 6, `${c.id} original CPU/WebGL output differs (max=${originalMaximum})`);
    }
    result.pixel_sha256 = sha(pixels);
    await persist();
  }
  assert.ok(!driver.console.some((item) => item.type === "pageerror" || item.type === "error"), JSON.stringify(driver.console));
  await writeFile(join(output, "chromium-console.json"), JSON.stringify(driver.console, null, 2) + "\n");
  const compressed = gzipSync(JSON.stringify({schema: report.schema, samples_include_warmup: true, runs: raw}) + "\n");
  await writeFile(join(output, "samples.json.gz"), compressed);
  report.raw_samples = {file: "samples.json.gz", sha256: sha(compressed), bytes: compressed.length};
  if (process.platform === "darwin") report.machine.power_after = command("pmset", ["-g", "batt"]);
  report.status = "passed";
  await persist();
} catch (error) {
  report.status = "failed";
  report.error = error.stack;
  if (driver) {
    await writeFile(join(output, "chromium-console.json"), JSON.stringify(driver.console, null, 2) + "\n");
    await driver.screenshot(join(output, "failure.png")).catch(() => {});
  }
  await persist();
  throw error;
} finally {
  await driver?.close();
  if (server) await new Promise((resolve) => server.close(resolve));
}

function instrumentation({total, warmup, linear, gpu, framebuffer}) {
  const state = window.capacity = {frames: new Float64Array(total * 8), count: 0, done: false, upload: 0, present: 0, surface: 0, uploadBytes: 0, uploadCalls: 0};
  const raf = window.requestAnimationFrame.bind(window);
  let previous = null, previousTimestamp = null;
  window.requestAnimationFrame = (callback) => raf((timestamp) => {
    if (state.done) return;
    const api = window.unpolishedPeas, before = api?.runtime?.peas_capacity_count?.() ?? 0;
    if (api && state.count === 0) {
      const canvas = document.querySelector("canvas");
      canvas.width = framebuffer.x;
      canvas.height = framebuffer.y;
    }
    const started = performance.now();
    state.upload = 0; state.present = 0; state.surface = 0; state.uploadBytes = 0; state.uploadCalls = 0;
    callback(timestamp);
    const finished = performance.now();
    if (!api || api.runtime.peas_capacity_count() === before) return;
    const i = state.count++ * 8;
    state.frames[i] = finished - started;
    state.frames[i + 1] = previous === null ? 0 : started - previous;
    state.frames[i + 2] = state.upload;
    state.frames[i + 3] = state.present;
    state.frames[i + 4] = previousTimestamp === null ? 0 : timestamp - previousTimestamp;
    state.frames[i + 5] = state.surface;
    state.frames[i + 6] = state.uploadBytes;
    state.frames[i + 7] = state.uploadCalls;
    previous = started; previousTimestamp = timestamp;
    if (state.count === warmup) {
      state.warmupMemory = api.host.imports.env.memory.buffer.byteLength;
      state.warmupResources = api.host.resourceCount();
    }
    if (state.count === total) state.done = true;
  });
  const prepared = new WeakSet();
  const prepare = (imports) => {
    if (prepared.has(imports)) return;
    prepared.add(imports);
    imports.env.peas_benchmark_now_ms = () => performance.now();
    for (const [name, stage] of [["up_host_gl_canvas_upload", "upload"], ["up_host_gl_texture_upload", "upload"], ["up_host_gl_surface_draw", "surface"], ["up_host_gl_present", "present"]]) {
      const original = imports.env[name];
      imports.env[name] = (...args) => {
        const started = performance.now();
        const result = original(...args);
        state[stage] += performance.now() - started;
        if (stage === "upload") {
          state.uploadBytes += args[name === "up_host_gl_canvas_upload" ? 3 : 4];
          state.uploadCalls += 1;
        }
        return result;
      };
    }
  };
  for (const name of ["instantiate", "instantiateStreaming"]) {
    const original = WebAssembly[name].bind(WebAssembly);
    WebAssembly[name] = async (source, imports) => {
      prepare(imports);
      const result = await original(source, imports);
      result.instance.exports.peas_capacity_linear(Number(linear));
      result.instance.exports.peas_capacity_gpu(Number(gpu));
      return result;
    };
  }
}
