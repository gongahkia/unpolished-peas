import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";

const path = process.argv[2];
assert.ok(path, "expected a Wasm path");

// The surface implementation is Canvas-backed, so this exercises the same
// allocation, drawing, and nearest-composition behavior that a browser host
// reaches before it uploads the final Canvas.
const memory = new WebAssembly.Memory({initial: 64});
const instance = await WebAssembly.instantiate(await readFile(path), {env: {memory}});
assert.equal(instance.instance.exports.renderSurfaceWasmSmoke() >>> 0, 0xff0000ff);
console.log("browser-render-surface passed");
