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
