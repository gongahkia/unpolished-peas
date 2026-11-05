import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {createBrowserInput, GamepadAxis, InputAbi, InputKey} from "../src/browser/input.mjs";

const fixture = JSON.parse(readFileSync(new URL("../src/fixtures/input/keyboard-pointer-v1.json", import.meta.url)));
assert.equal(fixture.schema_version, 1);
const fixtureCode = {up: "KeyW"}[fixture.key];
const fixtureButton = {left: 0}[fixture.pointer_button];
assert.equal(typeof fixtureCode, "string");
assert.equal(typeof fixtureButton, "number");

class Events {
  listeners = new Map();

  addEventListener(type, callback) { this.listeners.set(type, callback); }
  removeEventListener(type, callback) { if (this.listeners.get(type) === callback) this.listeners.delete(type); }
  emit(type, event = {}) { this.listeners.get(type)?.(event); return event; }
}

class Canvas extends Events {
  width = 320;
  height = 180;
  tabIndex = -1;
  focused = false;

  getBoundingClientRect() { return {left: 10, top: 20, width: 160, height: 90}; }
  focus() { this.focused = true; }
}

class Observer {
  static instances = [];
  constructor(callback) { this.callback = callback; Observer.instances.push(this); }
  observe(target) { this.target = target; }
  disconnect() { this.disconnected = true; }
}

const canvas = new Canvas();
const windowRef = new Events();
const documentRef = new Events();
documentRef.visibilityState = "visible";
const navigatorRef = {pads: [], getGamepads() { return this.pads; }};
const input = createBrowserInput({
  canvas,
  window: windowRef,
  document: documentRef,
  navigator: navigatorRef,
  ResizeObserver: Observer,
  mapCanvas: (x, y) => x >= 0 && y >= 0 && x < 320 && y < 180 ? {x: x / 2, y: y / 2} : null,
});

assert.equal(canvas.tabIndex, 0);
canvas.emit("focus");
const keyDown = windowRef.emit("keydown", {code: fixtureCode, preventDefault() { this.prevented = true; }});
assert.equal(keyDown.prevented, true);
canvas.emit("pointerdown", {button: fixtureButton, clientX: fixture.window[0], clientY: fixture.window[1]});
canvas.emit("wheel", {clientX: fixture.window[0], clientY: fixture.window[1], deltaX: 2, deltaY: -3, preventDefault() { this.prevented = true; }});
navigatorRef.pads = [{connected: true, index: 7, buttons: Array.from({length: 16}, (_, index) => ({pressed: index === 0, value: index === 0 ? 1 : 0})), axes: [-0.75, 0, 0, 0, 0, 0]}];
assert.equal(input.setActions([
  {name: "jump", binding: {key: "up"}},
  {name: "fire", binding: {pointer_button: "left"}},
  {name: "move", binding: {gamepad_axis: {axis: "left_x", sign: -1, threshold: 0.5}}},
]), true);
assert.deepEqual(input.actionValues(), [
  {context: "game", name: "jump", value: 1},
  {context: "game", name: "fire", value: 1},
  {context: "game", name: "move", value: 0.75},
]);
const state = input.snapshot();
assert.equal(state.down[InputKey[fixture.key]], true);
assert.deepEqual(state.pointer, {windowX: fixture.window[0], windowY: fixture.window[1], framebufferX: fixture.framebuffer[0], framebufferY: fixture.framebuffer[1], canvasX: fixture.canvas[0], canvasY: fixture.canvas[1], deltaX: 160, deltaY: 90, wheelX: 2, wheelY: -3});
assert.equal(state.gamepads[0].id, 7);
assert.equal(state.gamepads[0].buttons[0], true);
assert.equal(input.poll(), InputAbi.byteLength);
const memory = new WebAssembly.Memory({initial: 1});
assert.equal(input.read(0, InputAbi.byteLength - 1, memory), InputAbi.byteLength);
assert.equal(input.read(0, InputAbi.byteLength, memory), InputAbi.byteLength);
const view = new DataView(memory.buffer, 0, InputAbi.byteLength);
assert.equal(view.getUint32(0, true), 1);
assert.equal(view.getUint32(20, true) & (1 << InputKey.up), 1 << InputKey.up);
assert.equal(view.getUint32(36, true) & 1, 1);
assert.equal(view.getFloat32(60, true), 80);
assert.equal(view.getFloat32(64, true), 45);
assert.equal(view.getUint32(84, true), 1);
assert.equal(view.getInt32(88, true), 7);
assert.equal(view.getUint32(96, true) & 1, 1);
assert.equal(input.snapshot().pressed[InputKey.up], false);
// All motion before one simulation read must survive clicks and wheel events.
canvas.emit("pointermove", {clientX: 100, clientY: 70});
canvas.emit("pointermove", {clientX: 110, clientY: 80});
canvas.emit("wheel", {clientX: 110, clientY: 80, deltaY: 1});
assert.equal(input.snapshot().pointer.deltaX, 40);
assert.equal(input.snapshot().pointer.deltaY, 30);
input.read(0, InputAbi.byteLength, memory);
assert.equal(view.getFloat32(68, true), 40);
assert.equal(input.snapshot().pointer.deltaX, 0);

// Releasing W must not cancel a simultaneously held ArrowUp.
windowRef.emit("keydown", {code: "ArrowUp"});
windowRef.emit("keyup", {code: "KeyW"});
assert.equal(input.snapshot().down[InputKey.up], true);
assert.equal(input.snapshot().released[InputKey.up], false);
windowRef.emit("keyup", {code: "ArrowUp"});
assert.equal(input.snapshot().down[InputKey.up], false);
assert.equal(input.snapshot().released[InputKey.up], true);
windowRef.emit("keydown", {code: fixtureCode});

// Tab remains a select binding but must allow keyboard users to leave the game.
const tab = windowRef.emit("keydown", {code: "Tab", preventDefault() { this.prevented = true; }});
assert.equal(input.snapshot().down[InputKey.select], true);
assert.notEqual(tab.prevented, true);

// Standard Gamepad triggers are analog buttons, not extra stick axes.
navigatorRef.pads[0].mapping = "standard";
navigatorRef.pads[0].axes = [-0.75, 0, 0, 0];
navigatorRef.pads[0].buttons[6].value = 0.75;
navigatorRef.pads[0].buttons[7].value = 0.25;
assert.equal(input.snapshot().gamepads[0].axes[GamepadAxis.left_trigger], 0.75);
assert.equal(input.snapshot().gamepads[0].axes[GamepadAxis.right_trigger], 0.25);
input.read(0, InputAbi.byteLength, memory);
assert.equal(view.getFloat32(88 + 20 + GamepadAxis.left_trigger * 4, true), 0.75);
navigatorRef.pads[0].buttons[6].value = 0.5;
assert.equal(input.snapshot().gamepads[0].previousAxes[GamepadAxis.left_trigger], 0.75);
navigatorRef.pads[0].axes[0] = 0.25;
assert.equal(input.poll(), InputAbi.byteLength);
assert.equal(input.snapshot().gamepads[0].previousAxes[0], -0.75);
Observer.instances[0].callback();
assert.equal(input.snapshot().resizeEpoch, 1);
windowRef.emit("blur");
assert.equal(input.snapshot().down[InputKey[fixture.key]], false);
assert.equal(input.snapshot().pointerDown[fixtureButton], false);
assert.equal(input.snapshot().released[InputKey[fixture.key]], true);
assert.equal(input.snapshot().pointerReleased[fixtureButton], true);
canvas.emit("focus");
windowRef.emit("keydown", {code: "ArrowUp"});
windowRef.emit("keyup", {code: "ArrowUp"});
assert.equal(input.snapshot().down[InputKey.up], false, "blur clears physical aliases too");
documentRef.visibilityState = "hidden";
documentRef.emit("visibilitychange");
assert.equal(input.snapshot().visible, false);
navigatorRef.pads = [];
assert.equal(input.snapshot().gamepads.length, 0);
input.teardown();
assert.equal(canvas.listeners.size, 0);
assert.equal(windowRef.listeners.size, 0);
assert.equal(documentRef.listeners.size, 0);
assert.equal(Observer.instances[0].disconnected, true);

// Exercise actual v2 transport and the text-entry element lifecycle.
const {PhysicalKey, InputAbiV2} = await import("../src/browser/input.mjs");
const {EventKind} = await import("../src/browser/extended_input.mjs");
const keySource = readFileSync(new URL("../src/physical_key.zig", import.meta.url), "utf8");
for (const [, name, value] of keySource.matchAll(/^    (\w+) = (\d+),$/gm)) assert.equal(PhysicalKey[name], Number(value), name);
class TextElement extends Events {
  style = {};
  value = "";
  setAttribute() {}
  focus() { doc.activeElement = this; }
  remove() { this.removed = true; }
}
const doc = new Events(), win = new Events(), surface = new Canvas();
const elements = [];
doc.visibilityState = "visible";
doc.createElement = (tag) => { assert.equal(tag, "textarea"); const element = new TextElement(); elements.push(element); return element; };
doc.body = {appendChild() {}};
const extendedInput = createBrowserInput({canvas: surface, document: doc, window: win, navigator: {getGamepads: () => []}, ResizeObserver: null});
surface.emit("focus");
for (const code of ["KeyQ", "KeyE", "Digit1", "Digit2", "ShiftLeft"]) win.emit("keydown", {code});
win.emit("keydown", {code: "KeyQ", repeat: true});
assert.equal(extendedInput.snapshot().extended.down[PhysicalKey.q], true);
assert.equal(extendedInput.snapshot().extended.down[PhysicalKey.e], true);
assert.equal(extendedInput.snapshot().extended.down[PhysicalKey.digit_1], true);
assert.equal(extendedInput.snapshot().extended.down[PhysicalKey.digit_2], true);
assert.equal(extendedInput.setActions([{name: "q", binding: {physical_key: "q"}}]), true);
assert.equal(extendedInput.actionValues()[0].value, 1);
assert.equal(extendedInput.setActions([{name: "q", binding: {physical_key: "r"}}]), true);
assert.equal(extendedInput.actionValues()[0].value, 0);
assert.equal(extendedInput.setActions([{name: "q", binding: {physical_key: "toString"}}]), false);
assert.equal(extendedInput.actionValues()[0].value, 0);
const v2memory = new WebAssembly.Memory({initial: 1}), v2view = new DataView(v2memory.buffer);
function readV2() {
  v2view.setUint32(0, InputAbiV2.request, true);
  v2view.setUint32(4, 1, true);
  return extendedInput.read(0, InputAbiV2.byteLength, v2memory);
}
// Legacy readers may offer a larger buffer; only an explicit marker opts in.
assert.equal(extendedInput.read(0, InputAbiV2.byteLength, v2memory), InputAbi.byteLength);

v2view.setUint32(0, InputAbiV2.request, true);
v2view.setUint32(4, 1, true);
assert.equal(readV2(), InputAbiV2.byteLength);
assert.equal(v2view.getUint32(0, true), 2);
assert.equal(v2view.getUint8(378 + 96), 1);
const textElement = elements[0];
assert.equal(doc.activeElement, textElement);
textElement.emit("compositionstart");
textElement.emit("compositionupdate", {data: "ni"});
textElement.emit("input", {data: "你", inputType: "insertCompositionText", isComposing: true});
textElement.emit("compositionupdate", {data: "你好"});
textElement.emit("compositionend", {data: "你好"});
textElement.emit("input", {data: "你好", inputType: "insertText", isComposing: false});
let observed = extendedInput.snapshot().extended;
assert.deepEqual(observed.events.map((event) => event.kind), [EventKind.composition_start, EventKind.composition_update, EventKind.composition_update, EventKind.composition_end, EventKind.text_commit]);
assert.equal(observed.events.at(-1).text, "你好");
assert.equal(observed.composing, false);
assert.equal(readV2(), InputAbiV2.byteLength);
assert.equal(extendedInput.snapshot().extended.events.length, 0);
assert.equal(extendedInput.snapshot().extended.down[PhysicalKey.q], true);
const commitRecord = 378 + 104 + 4 * 12;
const payloadStart = 378 + 104 + 5 * 12;
assert.equal(v2view.getUint8(commitRecord), EventKind.text_commit);
const textOffset = v2view.getUint16(commitRecord + 4, true), textLength = v2view.getUint16(commitRecord + 6, true);
assert.equal(new TextDecoder().decode(new Uint8Array(v2memory.buffer, payloadStart + textOffset, textLength)), "你好");
// Some browsers deliver the committed input before compositionend.
textElement.emit("compositionstart");
textElement.value = "é";
textElement.emit("input", {data: "é", inputType: "insertFromComposition", isComposing: false});
textElement.emit("compositionend", {data: "é"});
assert.equal(extendedInput.snapshot().extended.events.filter((event) => event.kind === EventKind.text_commit).length, 1);
readV2();
textElement.value = "a".repeat(1024);
textElement.emit("input", {data: textElement.value, inputType: "insertText"});
textElement.value = "é";
textElement.emit("input", {data: textElement.value, inputType: "insertText"});
assert.equal(extendedInput.snapshot().extended.overflow, true);
assert.equal(extendedInput.snapshot().extended.events.length, 1);
readV2();
textElement.emit("compositionstart");
textElement.emit("compositionupdate", {data: "未完成"});
win.emit("blur");
observed = extendedInput.snapshot().extended;
assert.equal(observed.active, false);
assert.equal(observed.down[PhysicalKey.q], false);
assert(observed.events.some((event) => event.kind === EventKind.composition_cancel));
assert(!observed.events.some((event) => event.kind === EventKind.text_commit));
// A legacy caller still receives the original 376-byte version-1 packet.
assert.equal(extendedInput.read(0, InputAbi.byteLength, v2memory), InputAbi.byteLength);
assert.equal(v2view.getUint32(0, true), 1);
extendedInput.teardown();
assert.equal(textElement.removed, true);
assert.equal(win.listeners.size, 0);
