import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
const [wasmPath, nativePath] = process.argv.slice(2);
const native = JSON.parse(await readFile(nativePath, "utf8"));
native.progress = Array.from(Buffer.from(native.progress, "hex"));
const progress = new Uint8Array(native.progress);
assert.equal(new DataView(progress.buffer).getUint32(4, true), 11);
assert.equal(new TextDecoder().decode(progress.slice(18, 18 + progress[17])), "StartZoë你好");
const memory = new WebAssembly.Memory({initial: 64});
const {instance} = await WebAssembly.instantiate(await readFile(wasmPath), {env: {memory}});
for (let i = 0; i < 3; i += 1) {
  assert.equal(instance.exports.replay_probe_run(), 0);
  assert.equal(BigInt.asUintN(64, instance.exports.replay_probe_hash()), BigInt(native.hash));
  const bytes = new Uint8Array(memory.buffer, instance.exports.replay_probe_progress(), 82);
  assert.deepEqual(Array.from(bytes), native.progress);
}
console.log(`portable UPR5 session passed: initial score=7, final score=11, Unicode/binding/save bytes and native/Wasm pixels=${native.hash}`);
