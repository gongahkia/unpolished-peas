import assert from "node:assert/strict";
import {readFile, writeFile} from "node:fs/promises";
import {join} from "node:path";
import {sleep} from "./adapters.mjs";

export const check = (condition, message) => assert.ok(condition, message);
export async function ready(driver, focus = true) {
  await driver.wait(() => document.querySelector('[role="status"]')?.dataset.state === "ready", null, "game readiness");
  if (focus) await driver.click(".peas-actions button:first-child");
  await driver.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(true)))));
}

// Both transports call exactly this function. No PNG decoding dependency:
// present and read WebGL in one task, then sample logical pixel centres.
export function readFrame({width, height}) {
  const api = window.unpolishedPeas;
  const png = api.host.captureFrame();
  const gl = api.host.context();
  const physicalWidth = gl.drawingBufferWidth, physicalHeight = gl.drawingBufferHeight;
  const physical = new Uint8Array(physicalWidth * physicalHeight * 4);
  gl.readPixels(0, 0, physicalWidth, physicalHeight, gl.RGBA, gl.UNSIGNED_BYTE, physical);
  const error = gl.getError(), contextLost = gl.isContextLost();
  const rgba = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) {
    const px = Math.min(physicalWidth - 1, Math.floor((x + 0.5) * physicalWidth / width));
    const py = physicalHeight - 1 - Math.min(physicalHeight - 1, Math.floor((y + 0.5) * physicalHeight / height));
    rgba.set(physical.subarray((py * physicalWidth + px) * 4, (py * physicalWidth + px) * 4 + 4), (y * width + x) * 4);
  }
  const fixture = api.runtime.conformance_metric ? {x: api.runtime.conformance_metric(0), atlasFrame: api.runtime.conformance_metric(4)} : null;
  return {width, height, physicalWidth, physicalHeight, error, contextLost, png, rgba: Array.from(rgba), fixture, protocolFailure: api.runtime.up_browser_protocol_failure_phase()};
}

export async function frame(driver, directory, label, width, height) {
  const value = await driver.evaluate(readFrame, {width, height});
  check(value.error === 0 && !value.contextLost && value.protocolFailure === -1, `${label}: renderer/protocol must be healthy`);
  check(value.physicalWidth > 0 && value.physicalHeight > 0 && value.rgba.length === width * height * 4, `${label}: incomplete readback`);
  check(value.png?.startsWith("data:image/png") || (driver.name === "safari" && !driver.captureProbe.png_capture_available && value.png === null), `${label}: PNG capture failed despite independent probe`);
  await writeFile(join(directory, `${label}.rgba`), Buffer.from(value.rgba));
  if (value.png) await writeFile(join(directory, `${label}-canvas.png`), Buffer.from(value.png.split(",")[1], "base64"));
  const {rgba, png, ...metadata} = value;
  await writeFile(join(directory, `${label}-readback.json`), JSON.stringify({...metadata, pngCaptureAvailable: Boolean(png)}, null, 2) + "\n");
  return value;
}

export const pixel = (value, x, y) => value.rgba.slice((y * value.width + x) * 4, (y * value.width + x) * 4 + 4);
export const near = (actual, expected) => actual.length === expected.length && actual.every((value, index) => Math.abs(value - expected[index]) <= 1);

export async function compareReference(actual, reference) {
  const expected = await readFile(reference);
  check(actual.rgba.length === expected.length, "native/browser reference size differs");
  for (let index = 0; index < expected.length; index += 1) {
    if (Math.abs(actual.rgba[index] - expected[index]) > 1) throw new Error(`native/browser pixel mismatch: ${reference} byte=${index} expected=${expected[index]} actual=${actual.rgba[index]}`);
  }
}

export async function referenceFrame(driver, directory, label, reference) {
  const expected = await readFile(reference);
  const deadline = Date.now() + 15000;
  let actual;
  do {
    actual = await frame(driver, directory, label, 320, 180);
    if (actual.rgba.length === expected.length && actual.rgba.every((value, index) => Math.abs(value - expected[index]) <= 1)) return actual;
    await sleep(50);
  } while (Date.now() < deadline);
  await compareReference(actual, reference); // Preserve the exact mismatch.
}

export function composition({text, finish = false}) {
  const element = document.querySelector("textarea");
  if (!element || document.activeElement !== element) throw new Error("game text input is not focused");
  if (!finish) {
    element.dispatchEvent(new CompositionEvent("compositionstart", {bubbles: true, data: ""}));
    element.value = text;
    element.dispatchEvent(new CompositionEvent("compositionupdate", {bubbles: true, data: text}));
    element.dispatchEvent(new InputEvent("input", {bubbles: true, data: text, inputType: "insertCompositionText", isComposing: true}));
  } else {
    element.value = text;
    element.dispatchEvent(new CompositionEvent("compositionend", {bubbles: true, data: text}));
    // A post-composition input notification must not duplicate the commit.
    element.dispatchEvent(new InputEvent("input", {bubbles: true, data: text, inputType: "insertText", isComposing: false}));
  }
}
