import assert from "node:assert/strict";
import {createBrowserStorage, StorageStatus} from "../src/browser/storage.mjs";

class MemoryStorage {
  values = new Map();
  get length() { return this.values.size; }
  getItem(key) { return this.values.get(key) ?? null; }
  setItem(key, value) { this.values.set(key, value); }
  removeItem(key) { this.values.delete(key); }
}

const memory = new WebAssembly.Memory({initial: 1});
const bytes = new Uint8Array(memory.buffer);
const encoder = new TextEncoder();
const key = encoder.encode("bindings.up");
const value = new Uint8Array([0, 1, 2, 250, 255]);
bytes.set(key, 0);
bytes.set(value, 64);
const backend = new MemoryStorage();
const storage = createBrowserStorage({storage: backend, namespace: "peas:test"});
assert.deepEqual(storage.diagnostic(), {phase: "ready", namespace: "peas:test", maxValueBytes: 1024 * 1024, lastError: null});
assert.equal(storage.write(memory, 0, key.length, 64, value.length), StorageStatus.ok);
assert.ok(backend.getItem("peas:test/bindings.up").startsWith("UPST1:"));
assert.equal(storage.read(memory, 0, key.length, 128, 2), value.length);
assert.equal(storage.read(memory, 0, key.length, 128, value.length), value.length);
assert.deepEqual([...bytes.subarray(128, 128 + value.length)], [...value]);
assert.equal(storage.remove(memory, 0, key.length), StorageStatus.ok);
assert.equal(storage.read(memory, 0, key.length, 128, value.length), 0);
bytes[16] = 0xff;
assert.equal(storage.write(memory, 16, 1, 64, value.length), StorageStatus.invalidArgument);
assert.equal(createBrowserStorage({storage: null}).read(memory, 0, key.length, 128, value.length), StorageStatus.unavailable);

const failing = new MemoryStorage();
failing.setItem = () => { throw new Error("quota"); };
const failed = createBrowserStorage({storage: failing});
assert.equal(failed.write(memory, 0, key.length, 64, value.length), StorageStatus.rejected);
assert.deepEqual(failed.diagnostic(), {phase: "failed", namespace: "unpolished-peas:v1", maxValueBytes: 1024 * 1024, lastError: "write_failed"});
