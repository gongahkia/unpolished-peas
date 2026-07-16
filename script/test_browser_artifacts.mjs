import assert from "node:assert/strict";
import {createBrowserArtifacts} from "../src/browser/artifacts.mjs";

const canvas = {toDataURL(type) { assert.equal(type, "image/png"); return "data:image/png;base64,AA=="; }};
const artifacts = createBrowserArtifacts({canvas});
const memory = new WebAssembly.Memory({initial: 1});
new TextEncoder().encodeInto("shader compilation failed", new Uint8Array(memory.buffer));
assert.equal(artifacts.emit(memory, 0, 25), true);
assert.equal(artifacts.emit(memory, memory.buffer.byteLength, 1), false);
artifacts.recordTrace({name: "draw", ph: "X", ts: 1, dur: 2});
artifacts.recordCommand({tag: "rect", x: 1, y: 2});
assert.equal(artifacts.captureFrame(), "data:image/png;base64,AA==");
const values = artifacts.snapshot();
assert.deepEqual(values.map(({name}) => name), ["screenshot.png", "diagnostics.json", "trace.json", "commands.json"]);
assert.deepEqual(JSON.parse(values[1].data), {version: 1, messages: ["shader compilation failed"]});
assert.deepEqual(JSON.parse(values[2].data), {displayTimeUnit: "ms", traceEvents: [{name: "draw", ph: "X", ts: 1, dur: 2}]});
assert.deepEqual(JSON.parse(values[3].data), {version: 1, commands: [{tag: "rect", x: 1, y: 2}]});
