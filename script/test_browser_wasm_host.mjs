import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {createBrowserHost} from "../src/browser/host.mjs";

const path = process.argv[2] ?? "zig-out/web/unpolished-peas.wasm";
const instance = await WebAssembly.instantiate(await readFile(path), createBrowserHost().imports);
assert.equal(instance.instance.exports.up_browser_abi_version(), 1);
