import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";

const [wasmPath, nativePath] = process.argv.slice(2);
const native = BigInt((await readFile(nativePath, "utf8")).trim());
const {instance} = await WebAssembly.instantiate(await readFile(wasmPath), {
  env: {memory: new WebAssembly.Memory({initial: 128})},
});
for (let i = 0; i < 3; i += 1) {
  assert.equal(instance.exports.api_recipes_run(), 0, "portable API recipe assertions");
  assert.equal(BigInt.asUintN(64, instance.exports.api_recipes_hash()), native, "native/Wasm surface, Unicode replay and rebind recipe digest");
}
console.log("API reference recipes passed: native/Wasm hash=" + native + ", three lifecycles");
