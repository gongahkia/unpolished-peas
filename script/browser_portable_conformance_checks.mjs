import {join} from "node:path";
import {check, ready, frame, pixel, near, composition} from "./browser-authoring/checks.mjs";
import {sleep} from "./browser-authoring/adapters.mjs";

export async function portableChecks(driver, {directory}) {
  const start = async () => {
    await ready(driver);
    await driver.evaluate(() => {
      window.progress = () => {
        const {runtime, host} = window.unpolishedPeas;
        const pointer = runtime.conformance_snapshot();
        const view = new DataView(host.memory.buffer, pointer, 82);
        return {score: view.getUint32(4, true), one: view.getUint32(8, true), two: view.getUint32(12, true), rebound: Boolean(view.getUint8(16)), name: new TextDecoder().decode(new Uint8Array(host.memory.buffer, pointer + 18, view.getUint8(17)))};
      };
      window.savedProgress = () => localStorage.getItem(window.unpolishedPeas.host.storageKey("peas.portable-conformance:progress"));
    });
  };
  await start();
  const rendered = await frame(driver, directory, "consumer-initial", 320, 160);
  let glyphs = 0;
  for (let y = 8; y < 25; y += 1) for (let x = 8; x < 200; x += 1) if (pixel(rendered, x, y)[0] > 100) glyphs += 1;
  const yellow = [255, 198, 74, 255];
  check(near(pixel(rendered, 28, 50), yellow) && near(pixel(rendered, rendered.fixture.x + (rendered.fixture.atlasFrame === 0 ? 14 : 0), 54), yellow) && glyphs > 50, "authored image/font/atlas pixels");
  check(await driver.evaluate(() => window.progress().score === 0 && window.savedProgress() === null), "isolated empty consumer progress");
  await driver.down("q");
  await driver.wait(() => window.unpolishedPeas.runtime.conformance_metric(0) < 120, null, "physical Q movement");
  await driver.up("q");
  await driver.wait(() => !window.unpolishedPeas.host.input().extended.down[20], null, "physical Q release");
  const beforeE = await driver.evaluate(() => window.unpolishedPeas.runtime.conformance_metric(0));
  await driver.down("e");
  await driver.wait((x) => window.unpolishedPeas.runtime.conformance_metric(0) > x, beforeE, "physical E movement");
  await driver.up("e");
  await driver.wait(() => !window.unpolishedPeas.host.input().extended.down[8], null, "physical E release");
  await driver.evaluate(() => window.unpolishedPeas.runtime.up_browser_set_paused(1));
  await driver.press("1"); await driver.press("2");
  await sleep(50);
  await driver.evaluate(() => window.unpolishedPeas.runtime.up_browser_set_paused(0));
  await driver.wait(() => window.progress().one === 1 && window.progress().two === 1, null, "complete paused taps");
  check(await driver.evaluate(() => window.progress().score === 3), "distinct 1/2 actions");
  await driver.press("F5");
  await driver.wait(() => window.progress().rebound, null, "key rebinding");
  await sleep(50);
  const beforeQ = await driver.evaluate(() => window.unpolishedPeas.runtime.conformance_metric(0));
  await driver.down("q"); await sleep(75); await driver.up("q");
  check(await driver.evaluate((x) => window.unpolishedPeas.runtime.conformance_metric(0) === x, beforeQ), "old Q binding must be inactive");
  await driver.down("r");
  await driver.wait((x) => window.unpolishedPeas.runtime.conformance_metric(0) < x, beforeQ, "rebound R movement");
  await driver.up("r");
  await driver.press("F4");
  await driver.wait(() => document.activeElement?.tagName === "TEXTAREA", null, "text-input focus");
  // These DOM events exercise host composition, not a physical OS IME.
  await driver.evaluate(composition, {text: "Zo"});
  await driver.wait(() => window.unpolishedPeas.runtime.conformance_metric(1) === 2, null, "injected preedit");
  check(await driver.evaluate(() => window.progress().name === ""), "preedit must not commit/save");
  await driver.evaluate(composition, {text: "Zoë", finish: true});
  await driver.wait(() => window.progress().name === "Zoë" && window.unpolishedPeas.runtime.conformance_metric(1) === 0, null, "one composition commit");
  // Real automation text insertion reaches the browser's input machinery.
  await driver.text("你好");
  await driver.wait(() => window.progress().name === "Zoë你好", null, "Unicode committed text");
  const inputEvidence = await driver.evaluate(() => ({trustedKeys: window.peasTest.trustedKeys, trustedInput: window.peasTest.trustedInput, injectedComposition: window.peasTest.injectedComposition}));
  check(inputEvidence.trustedKeys > 0 && inputEvidence.trustedInput > 0 && inputEvidence.injectedComposition > 0, "record trusted keys/input separately from injected composition");
  await driver.press("F4");
  await driver.wait(() => document.activeElement?.tagName === "CANVAS", null, "canvas focus restored");
  await driver.press("Space");
  await driver.wait(() => window.progress().score === 4 && window.peasTest.nonzero > 0, null, "audio activation and saved score");
  const stored = await driver.evaluate(() => window.savedProgress());
  await driver.evaluate(() => { window.peasTest.rejectProgressWrites = true; });
  await driver.press("1");
  await driver.wait(() => window.progress().score === 5, null, "gameplay during rejected save");
  check(await driver.evaluate((old) => window.savedProgress() === old, stored), "rejected write preserves stored progress");
  check(await driver.evaluate(() => window.unpolishedPeas.runtime.up_browser_protocol_failure_phase()) === -1, "save rejection must be recoverable");
  await driver.evaluate(() => { window.peasTest.rejectProgressWrites = false; });
  await driver.press("2");
  await driver.wait(() => window.progress().score === 7, null, "save retry");
  await driver.reload(); await start();
  check(await driver.evaluate(() => {
    const p = window.progress(); return p.score === 7 && p.one === 2 && p.two === 2 && p.rebound && p.name === "Zoë你好";
  }), "actual reload restores scores, binding and exact Unicode");
  await driver.press("F4");
  await driver.wait(() => document.activeElement?.tagName === "TEXTAREA", null, "failure-test text focus");
  await driver.evaluate(composition, {text: "未"});
  await driver.wait(() => window.unpolishedPeas.runtime.conformance_metric(1) > 0, null, "failure-test preedit");
  const lifecycle = await driver.evaluate(() => {
    const {runtime, host} = window.unpolishedPeas;
    const before = runtime.conformance_cleanups();
    runtime.conformance_reject_next_init();
    const rejected = runtime.up_browser_init(320, 160);
    const failedCleanups = runtime.conformance_cleanups();
    const failedFrames = host.lifecycle().scheduledFrames;
    const failedText = host.input().extended;
    const recovered = runtime.up_browser_init(320, 160);
    return {before, rejected, failedCleanups, failedFrames, failedTextActive: failedText.active, failedComposing: failedText.composing, recovered, scheduledFrames: host.lifecycle().scheduledFrames};
  });
  check(lifecycle.rejected === -3 && lifecycle.failedCleanups === lifecycle.before + 2, "old and partially initialized games each clean once");
  check(lifecycle.failedFrames === 0 && !lifecycle.failedTextActive && !lifecycle.failedComposing, "failed init cancels callbacks and text session");
  check(lifecycle.recovered === 0 && lifecycle.scheduledFrames === 1, "retry schedules exactly one frame");
  check(await driver.evaluate(() => window.progress().name === "Zoë你好"), "canceled preedit cannot leak into saves");
  await frame(driver, directory, "consumer-recovered", 320, 160);
  await driver.screenshot(join(directory, "consumer.png"));
  const shutdown = await driver.evaluate(() => {
    const {runtime, host} = window.unpolishedPeas;
    const before = runtime.conformance_cleanups();
    runtime.up_browser_shutdown();
    const after = runtime.conformance_cleanups();
    runtime.up_browser_shutdown();
    return {before, after, second: runtime.conformance_cleanups(), pointer: runtime.conformance_snapshot(), scheduled: host.lifecycle().scheduledFrames, textElements: document.querySelectorAll("textarea").length};
  });
  check(shutdown.after === shutdown.before + 1 && shutdown.second === shutdown.after && shutdown.pointer === 0 && shutdown.scheduled === 0 && shutdown.textElements === 0, "shutdown releases game, text and callbacks exactly once");
  return {status: "peas-portable-conformance-passed", glyphs, inputEvidence, composition: "injected DOM events; physical IME unverified", unicodeCommit: "browser automation input", lifecycle, shutdown};
}
