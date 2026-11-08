import {join} from "node:path";
import {readFile, writeFile} from "node:fs/promises";
import {check, ready, frame} from "./browser-authoring/checks.mjs";

export async function surfaceChecks(driver, {directory, references}) {
  await ready(driver);
  const metadata = JSON.parse(await readFile(join(references, "surface.json"), "utf8"));
  check(metadata.cases === 12 && metadata.width === 48 && metadata.height === 32, "complete CPU fixture required");
  const observations = {reference: metadata, cases: [], creationFailures: []};
  observations.renderer = await driver.evaluate(() => {
    const gl = window.unpolishedPeas.host.context();
    const debug = gl.getExtension("WEBGL_debug_renderer_info");
    return {version: gl.getParameter(gl.VERSION), vendor: debug ? gl.getParameter(debug.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR), renderer: debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER)};
  });
  async function select(index) {
    const before = await driver.evaluate(index => {
      const api = window.unpolishedPeas;
      if (api.runtime.surface_probe_case(index) !== 0) throw new Error("invalid fixture case");
      return api.runtime.surface_probe_metric(1);
    }, index);
    await driver.wait(({index, before}) => {
      const runtime = window.unpolishedPeas.runtime;
      return runtime.surface_probe_metric(0) === index && runtime.surface_probe_metric(1) > before;
    }, {index, before}, `surface case ${index}`);
  }
  async function compare(index, label = `surface-${index}`) {
    const actual = await frame(driver, directory, label, metadata.width, metadata.height);
    const expected = await readFile(join(references, `surface-${index}.rgba`));
    check(expected.length === actual.rgba.length, `${label}: reference dimensions`);
    let maximum = 0, differingChannels = 0;
    for (let i = 0; i < expected.length; i += 1) {
      const delta = Math.abs(actual.rgba[i] - expected[i]);
      maximum = Math.max(maximum, delta);
      if (delta) differingChannels += 1;
      if (i % 4 === 3) check(actual.rgba[i] === 255, `${label}: opaque final alpha`);
    }
    const tolerance = metadata.exact_cases.includes(index) ? 0 : metadata.tolerance;
    check(maximum <= tolerance, `${label}: max channel delta ${maximum} exceeds ${tolerance}; inspect RGBA artifacts`);
    const resources = await driver.evaluate(() => window.unpolishedPeas.host.resourceCount());
    check(resources === (index === 10 ? 0 : 3), `${label}: bounded live resources, got ${resources}`);
    return {index, label, maximumChannelDelta: maximum, differingChannels, tolerance, resources};
  }
  for (let index = 0; index < metadata.cases; index += 1) {
    await select(index);
    observations.cases.push(await compare(index));
  }
  for (let repeat = 0; repeat < 12; repeat += 1) {
    await select(9); // release/re-retain every frame; stale handles are rejected in Zig.
    check(await driver.evaluate(() => window.unpolishedPeas.host.resourceCount()) === 3, "generation churn must not retain textures");
    await select(10);
    check(await driver.evaluate(() => window.unpolishedPeas.host.resourceCount()) === 0, "CPU fallback releases all compositor textures");
  }
  // Inject failure into real resource creation, after earlier allocations have
  // succeeded. Restore the driver method in the same task, then retry normally.
  for (const failAt of [0, 1, 2]) {
    await select(10);
    const failure = await driver.evaluate(failAt => {
      const api = window.unpolishedPeas, gl = api.host.context();
      const original = gl.createTexture;
      let calls = 0;
      gl.createTexture = function(...args) { return calls++ === failAt ? null : original.apply(this, args); };
      try {
        api.runtime.surface_probe_case(0);
        api.runtime.up_browser_frame(performance.now());
        return {status: api.runtime.up_browser_canvas_render_status(), resources: api.host.resourceCount(), calls};
      } finally { gl.createTexture = original; }
    }, failAt);
    check(failure.calls === failAt + 1 && failure.status !== 0 && failure.resources === 0, `creation failure ${failAt}: rollback ${JSON.stringify(failure)}`);
    observations.creationFailures.push({failAt, ...failure});
    await select(0);
    await compare(0, `surface-retry-${failAt}`);
  }
  await select(1);
  const canLose = await driver.evaluate(() => {
    const api = window.unpolishedPeas;
    window.surfaceLoseContext = api.host.context().getExtension("WEBGL_lose_context");
    if (!window.surfaceLoseContext) return false;
    window.surfaceRecoveries = api.host.lifecycle().recoveries;
    window.surfaceLoseContext.loseContext();
    return true;
  });
  if (canLose) {
    await driver.wait(() => window.unpolishedPeas.host.lifecycle().phase === "context_lost", null, "actual WebGL context loss");
    await driver.evaluate(() => window.surfaceLoseContext.restoreContext());
    await driver.wait(() => window.unpolishedPeas.host.lifecycle().recoveries > window.surfaceRecoveries && !window.unpolishedPeas.host.context().isContextLost(), null, "actual WebGL context restoration");
    await select(1);
    observations.recovered = await compare(1, "surface-restored");
  } else observations.recovered = {status: "unverified", blocker: "WEBGL_lose_context extension unavailable"};
  await driver.evaluate(() => {
    const canvas = document.querySelector("canvas[data-unpolished-peas]");
    canvas.width = 96; canvas.height = 64;
  });
  await select(8);
  observations.resized = await compare(8, "surface-resized-fresh-source");
  await driver.screenshot(join(directory, "surface-composition.png"));
  check(await driver.evaluate(() => window.unpolishedPeas.runtime.up_browser_protocol_failure_phase()) === -1, "fixture remains healthy");
  await driver.evaluate(() => window.unpolishedPeas.runtime.up_browser_shutdown());
  observations.shutdown = await driver.evaluate(() => ({resources: window.unpolishedPeas.host.resourceCount(), lifecycle: window.unpolishedPeas.host.lifecycle()}));
  check(observations.shutdown.resources === 0 && observations.shutdown.lifecycle.scheduledFrames === 0, "shutdown releases resources and cancels frames");
  await writeFile(join(directory, "surface-observations.json"), JSON.stringify(observations, null, 2) + "\n");
  return observations;
}
