import assert from "node:assert/strict";
import {mkdir, readFile, writeFile} from "node:fs/promises";
const [wasmPath, nativePath] = process.argv.slice(2);
const native = JSON.parse(await readFile(nativePath, "utf8"));
const memory = new WebAssembly.Memory({initial: 256});
const {instance} = await WebAssembly.instantiate(await readFile(wasmPath), {env: {memory}});
const runs = [];
for (let i = 0; i < 3; i += 1) {
  assert.equal(instance.exports.audio_lifetime_run(), 0, "audio lifetime stage=" + instance.exports.audio_lifetime_stage());
  assert.equal(BigInt.asUintN(64, instance.exports.audio_lifetime_hash()), BigInt(native.pcm_hash));
  const run = {retained: [], released: [], allocation_failures: instance.exports.audio_lifetime_failures()};
  assert.ok(run.allocation_failures >= 20);
  for (let release = 0; release <= 1; release += 1) {
    for (let index = 0; index < 4; index += 1) {
      const values = [0, 1, 2, 3].map((field) => instance.exports.audio_lifetime_sample(release, index, field));
      const sample = Object.fromEntries(["cycles", "sound_slots", "music_slots", "live_bytes"].map((key, j) => [key, values[j]]));
      assert.equal(sample.cycles, native.retained[index].cycles);
      assert.equal(sample.sound_slots, release ? 1 : sample.cycles);
      assert.equal(sample.music_slots, release ? 1 : sample.cycles);
      run[release ? "released" : "retained"].push(sample);
    }
  }
  assert.ok(run.released.every((sample) => sample.live_bytes === run.released[0].live_bytes));
  assert.ok(run.retained[3].live_bytes > run.retained[0].live_bytes * 200);
  run.memory_bytes = memory.buffer.byteLength;
  runs.push(run);
}
assert.equal(runs[2].memory_bytes, runs[1].memory_bytes, "linear memory must plateau across warmed lifecycles");
assert.ok(native.released.every((sample) => sample.live_bytes === native.released[0].live_bytes));
await mkdir("zig-out/diagnostics/audio-lifetime", {recursive: true});
await writeFile("zig-out/diagnostics/audio-lifetime/conformance.json", JSON.stringify({native, wasm: runs}, null, 2) + "\n");
console.log(`audio lifetime native/Wasm passed: 12 music modes, overlapping SFX, stale handles, exhaustion, ${native.allocation_failures}/${runs[0].allocation_failures} allocation failures; retained metadata ${native.released[0].live_bytes}/${runs[0].released[0].live_bytes} bytes`);
