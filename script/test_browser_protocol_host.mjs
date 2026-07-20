import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {createBrowserHost, Status} from "../src/browser/host.mjs";

const instance = await WebAssembly.instantiate(await readFile("zig-out/web/unpolished-peas-protocol.wasm"), createBrowserHost().imports);
const runtime = instance.instance.exports;
assert.equal(runtime.up_browser_protocol_init(), Status.ok);
assert.equal(runtime.up_browser_protocol_frame(1 / 60, 0.5), Status.ok);
assert.equal(runtime.up_browser_protocol_failure_phase(), -1);
assert.equal(runtime.up_browser_protocol_frame(Number.NaN, 0), Status.rejected);
assert.equal(runtime.up_browser_protocol_failure_phase(), 1);
assert.equal(runtime.up_browser_protocol_headless_image_hash(), runtime.up_browser_protocol_headless_expected_image_hash());
assert.equal(runtime.up_browser_protocol_headless_command_count(), 1);
