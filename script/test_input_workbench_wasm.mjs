import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {createBrowserInput, InputAbiV2} from "../src/browser/input.mjs";

const memory = new WebAssembly.Memory({initial: 64});
const {instance} = await WebAssembly.instantiate(await readFile(process.argv[2]), {env: {memory}});
const api = instance.exports;
assert.equal(api.input_init(), 0);
class Events {
  listeners = new Map();
  addEventListener(type, callback) { this.listeners.set(type, callback); }
  removeEventListener(type) { this.listeners.delete(type); }
  emit(type, event = {}) { this.listeners.get(type)?.(event); }
}
const win = new Events(), doc = new Events(), canvas = new Events();
canvas.width = 320; canvas.height = 180; canvas.tabIndex = 0;
doc.visibilityState = "visible";
doc.body = {appendChild() {}};
let textarea;
doc.createElement = () => {
  textarea = new Events(); textarea.style = {}; textarea.value = "";
  textarea.setAttribute = () => {}; textarea.remove = () => {};
  textarea.focus = () => { doc.activeElement = textarea; };
  return textarea;
};
const input = createBrowserInput({canvas, window: win, document: doc, navigator: {getGamepads: () => []}, ResizeObserver: null});
canvas.emit("focus");
function submit() {
  const destination = api.input_destination();
  const view = new DataView(memory.buffer);
  view.setUint32(destination, InputAbiV2.request, true);
  view.setUint32(destination + 4, api.input_text_requested(), true);
  const length = input.read(destination, InputAbiV2.byteLength, memory);
  assert.equal(length, InputAbiV2.byteLength);
  assert.equal(api.input_submit(length), 0);
}
const tick = () => assert.equal(api.input_tick(), 0);
for (const code of ["KeyQ", "Digit1", "Digit2"]) win.emit("keydown", {code});
submit(); // Presentation frame with zero updates.
win.emit("keyup", {code: "KeyQ"});
win.emit("keydown", {code: "F5"});
win.emit("keydown", {code: "KeyR"});
submit(); tick();
assert.equal(api.input_x(), 149);
assert.equal(api.input_one(), 1); assert.equal(api.input_two(), 1);
tick(); // Catch-up update retains R without repeating presses.
assert.equal(api.input_x(), 148); assert.equal(api.input_one(), 1);
for (const code of ["KeyR", "F5", "Digit1", "Digit2"]) win.emit("keyup", {code});
win.emit("keydown", {code: "F4"});
submit(); tick();
assert.equal(api.input_text_requested(), 1);
submit(); tick(); // Portable request activates the DOM textarea.
assert.equal(doc.activeElement, textarea);
textarea.emit("compositionstart");
textarea.emit("compositionupdate", {data: "Zo"});
submit(); tick();
assert.equal(api.input_preedit_length(), 2); assert.equal(api.input_name_length(), 0);
textarea.emit("compositionupdate", {data: "Zoë"});
submit(); // Another zero-update frame, preserving this event's order.
textarea.emit("compositionend", {data: "Zoë你好"});
textarea.emit("input", {data: "Zoë你好", inputType: "insertText", isComposing: false});
submit(); tick();
const name = new TextDecoder().decode(new Uint8Array(memory.buffer, api.input_name(), api.input_name_length()));
assert.equal(name, "Zoë你好"); assert.equal(api.input_preedit_length(), 0);
assert.equal(api.input_round_trip(), 0, "DOM → v2 ABI → fixed ticks → game → UPR5 → same headless game");
api.input_deinit(); input.teardown();
console.log("browser input v2 and workbench Wasm passed: Q/E/1/2, rebinding, buffering, Unicode, composition, replay");
