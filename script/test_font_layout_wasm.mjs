import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
const [wasmPath, nativePath] = process.argv.slice(2);
const native = JSON.parse(await readFile(nativePath, "utf8"));
const {instance} = await WebAssembly.instantiate(await readFile(wasmPath), {
  env: {memory: new WebAssembly.Memory({initial: 128})},
});
for (let i = 0; i < 3; i += 1) {
  assert.equal(instance.exports.font_layout_run(), 0,
    "font layout case=" + instance.exports.font_layout_failure_case() + " pixel=" + instance.exports.font_layout_failure_pixel());
  assert.equal(instance.exports.font_layout_cases(), native.cases);
  assert.equal(BigInt.asUintN(64, instance.exports.font_layout_pixels()), BigInt(native.pixel_hash));
  assert.equal(BigInt.asUintN(64, instance.exports.font_layout_metrics()), BigInt(native.metrics_hash));
}
assert.ok(native.cases >= 327);
assert.equal(native.legacy_www, 12);
assert.equal(native.authored_www, 36);
assert.equal(native.authored_iii, 12);
console.log("font layout native/Wasm passed: " + native.cases + " exact pixel/metric cases, limits/ownership checks, three lifecycles");
