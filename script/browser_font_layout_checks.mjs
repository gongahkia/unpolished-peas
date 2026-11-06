import {join} from "node:path";
import {readFile} from "node:fs/promises";
import {check, ready, referenceFrame} from "./browser-authoring/checks.mjs";

export async function fontChecks(driver, {directory, references}) {
  await ready(driver);
  const metadata = JSON.parse(await readFile(join(references, "font.json"), "utf8"));
  check(metadata.wide.width > metadata.narrow.width && metadata.dialogue_lines > 1, "native reference must contain proportional metrics and wrapped text");
  await referenceFrame(driver, directory, "font-initial", join(references, "font-initial.rgba"));
  await driver.press("ArrowDown");
  await referenceFrame(driver, directory, "font-selected", join(references, "font-selected.rgba"));
  await driver.press("Space");
  await referenceFrame(driver, directory, "font-dialogue", join(references, "font-dialogue.rgba"));
  await driver.screenshot(join(directory, "font-layout.png"));
  check(await driver.evaluate(() => window.unpolishedPeas.runtime.up_browser_protocol_failure_phase()) === -1, "font game must remain healthy");
  await driver.evaluate(() => window.unpolishedPeas.runtime.up_browser_shutdown());
  check(await driver.evaluate(() => window.unpolishedPeas.host.lifecycle().scheduledFrames) === 0, "font game shutdown cancels frames");
  return {status: "peas-font-layout-passed", comparedPixels: 3 * 320 * 180, tolerance: 1, reference: metadata};
}
