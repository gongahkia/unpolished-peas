import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";

const [wasmPath, nativePath] = process.argv.slice(2);
const native = JSON.parse(await readFile(nativePath, "utf8"));
assert.equal(native.score, 2);
assert.equal(native.saved, 2);
assert.notEqual(native.hash, "0");
const memory = new WebAssembly.Memory({initial: 64});
const {instance} = await WebAssembly.instantiate(await readFile(wasmPath), {env: {memory}});
for (let iteration = 0; iteration < 3; iteration += 1) {
  assert.equal(instance.exports.asset_run(), 0, "Wasm game must initialize, step, draw, save and clean up");
  assert.equal(BigInt.asUintN(64, instance.exports.asset_hash()), BigInt(native.hash), "native and browser-Wasm pixels must match");
  assert.equal(instance.exports.asset_score(), native.score);
  assert.equal(instance.exports.asset_saved(), native.saved);
}
console.log(`portable asset collection passed: native/Wasm pixels=${native.hash}, score=2, saved=2, three lifecycles`);
