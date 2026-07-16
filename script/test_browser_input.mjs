import assert from "node:assert/strict";
import {createBrowserInput, InputAbi, InputKey} from "../src/browser/input.mjs";

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
const keyDown = windowRef.emit("keydown", {code: "KeyW", preventDefault() { this.prevented = true; }});
assert.equal(keyDown.prevented, true);
canvas.emit("pointerdown", {button: 0, clientX: 90, clientY: 65});
canvas.emit("wheel", {clientX: 90, clientY: 65, deltaX: 2, deltaY: -3, preventDefault() { this.prevented = true; }});
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
assert.equal(state.down[InputKey.up], true);
assert.deepEqual(state.pointer, {windowX: 90, windowY: 65, framebufferX: 160, framebufferY: 90, canvasX: 80, canvasY: 45, deltaX: 0, deltaY: 0, wheelX: 2, wheelY: -3});
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
navigatorRef.pads[0].axes[0] = 0.25;
assert.equal(input.poll(), InputAbi.byteLength);
assert.equal(input.snapshot().gamepads[0].previousAxes[0], -0.75);
Observer.instances[0].callback();
assert.equal(input.snapshot().resizeEpoch, 1);
windowRef.emit("blur");
assert.equal(input.snapshot().down[InputKey.up], false);
assert.equal(input.snapshot().pointerDown[0], false);
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
