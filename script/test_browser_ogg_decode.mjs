import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";

const path = process.argv[2];
assert.ok(path, "expected a Wasm path");
const memory = new WebAssembly.Memory({initial: 64});
const instance = await WebAssembly.instantiate(await readFile(path), {env: {memory}});
assert.equal(instance.instance.exports.up_browser_ogg_decode_smoke(), 0);
console.log("browser-ogg-decode passed");
