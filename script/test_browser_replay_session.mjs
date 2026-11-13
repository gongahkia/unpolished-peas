import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";

const path = process.argv[2];
assert.ok(path, "expected the session replay Wasm fixture");
const memory = new WebAssembly.Memory({initial: 64});
const {instance} = await WebAssembly.instantiate(await readFile(path), {env: {memory}});
const actual = BigInt.asUintN(64, instance.exports.replaySessionWasmSmoke());
const failure = new TextDecoder().decode(new Uint8Array(memory.buffer,
  instance.exports.replayFailurePointer(), instance.exports.replayFailureLength()));
assert.equal(failure, "");
// Independent FNV-1a over score=10 and variation=2 as little-endian u32s.
let expected = 14695981039346656037n;
for (const byte of [10, 0, 0, 0, 2, 0, 0, 0]) {
  expected = BigInt.asUintN(64, (expected ^ BigInt(byte)) * 1099511628211n);
}
assert.equal(actual, expected);
console.log("browser session replay and portable state hash passed");
