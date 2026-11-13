import {join} from "node:path";
import {check, ready, frame} from "./browser-authoring/checks.mjs";
import {sleep} from "./browser-authoring/adapters.mjs";

export async function audioChecks(driver, {directory}) {
  await ready(driver, false);
  const metric = (field) => driver.evaluate((field) => window.unpolishedPeas.runtime.audio_lifetime_metric(field), field);
  check(await metric(0) === 1 && await metric(6) === 2 && await metric(7) === 1, "initial sources loaded once");
  check(await metric(5) === 0, "autoplay must initially be blocked; sources stay available for retry");
  const initially = await driver.evaluate(() => window.unpolishedPeas.host.audio());
  await driver.click(".peas-actions button:first-child");
  await driver.click("canvas[data-unpolished-peas]");
  await driver.wait(() => window.unpolishedPeas.host.audio().state === 0, null, "WebAudio gesture activation");
  for (let i = 0; i < 12; i += 1) {
    const before = await metric(0);
    await driver.press("Space");
    await driver.wait((value) => window.unpolishedPeas.runtime.audio_lifetime_metric(0) > value, before, "audio scene transition");
    check(await metric(2) === 3 && await metric(3) === 2, "reuse sound/music registry slots");
    check(await metric(6) === 2 && await metric(7) === 1, "retain only persistent UI and current scene sources");
    check(await metric(5) === 1, "activated audio starts through retained handles");
    await driver.press("Escape");
    await driver.wait(() => window.unpolishedPeas.runtime.audio_lifetime_metric(4) === 2, null, "pause outgoing music");
  }
  await driver.wait(() => window.peasTest.nonzero > 0, null, "accepted nonzero WebAudio PCM");
  check(await driver.evaluate(() => window.unpolishedPeas.runtime.up_browser_protocol_failure_phase()) === -1, "audio host remains healthy");
  const observations = await driver.evaluate(() => ({transitions: window.unpolishedPeas.runtime.audio_lifetime_metric(0), submitted: window.peasTest.submissions, nonzero: window.peasTest.nonzero, invalidPcm: window.peasTest.invalidPcm, audio: window.unpolishedPeas.host.audio()}));
  check(observations.invalidPcm === 0, "submitted PCM must be finite");
  const rendered = await frame(driver, directory, "audio-lifetime", 320, 120);
  check(rendered.rgba.some((value, index) => index % 4 !== 3 && value > 150), "audio example text must render");
  await driver.screenshot(join(directory, "audio-lifetime.png"));
  const atShutdown = await driver.evaluate(() => {
    window.unpolishedPeas.runtime.up_browser_shutdown();
    return window.peasTest.submissions;
  });
  check(await metric(8) === 1, "game releases playback before host teardown");
  await sleep(100);
  check(await driver.evaluate(() => window.peasTest.submissions) === atShutdown, "shutdown stops new PCM submissions");
  return {status: "peas-audio-lifetime-passed", initially, ...observations};
}
