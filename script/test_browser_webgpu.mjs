import assert from "node:assert/strict";
import {Status, createBrowserHost} from "../src/browser/host.mjs";
import {WebGpuBackendError, createWebGpuBackend} from "../src/browser/webgpu_backend.mjs";

class FakeCanvas {
  width = 0;
  height = 0;
  calls = [];
  listeners = new Map();
  context = {
    configure: (value) => this.calls.push(["configure", value]),
    getCurrentTexture: () => ({createView: () => "view"}),
    unconfigure: () => this.calls.push(["unconfigure"]),
  };

  getContext(name) {
    assert.equal(name, "webgpu");
    return this.context;
  }

  addEventListener(name, callback) {
    this.listeners.set(name, callback);
  }

  removeEventListener(name, callback) {
    if (this.listeners.get(name) === callback) this.listeners.delete(name);
  }
}

let resolveLost;
const lost = new Promise((resolve) => { resolveLost = resolve; });
const submissions = [];
const passes = [];
const writes = [];
const textureWrites = [];
const draws = [];
const device = {
  lost,
  queue: {submit: (commands) => submissions.push(commands), writeBuffer: (...args) => writes.push(args), writeTexture: (...args) => textureWrites.push(args)},
  createShaderModule: () => "shader",
  createRenderPipeline: () => ({getBindGroupLayout: () => "sprite-layout"}),
  createBuffer: () => ({destroy() { submissions.push("buffer-destroy"); }}),
  createTexture: () => ({createView: () => "texture-view", destroy() { submissions.push("texture-destroy"); }}),
  createSampler: () => "sampler",
  createBindGroup: () => "bind-group",
  createCommandEncoder: () => ({
    beginRenderPass: (descriptor) => {
      passes.push(descriptor);
      return {setPipeline() {}, setVertexBuffer() {}, setBindGroup() {}, draw: (count) => draws.push(count), end() {}};
    },
    finish: () => "command-buffer",
  }),
  destroy: () => submissions.push("destroy"),
};
const adapter = {requestDevice: async () => device};
const navigatorRef = {gpu: {requestAdapter: async () => adapter, getPreferredCanvasFormat: () => "bgra8unorm"}};
const canvas = new FakeCanvas();
const losses = [];
const backend = await createWebGpuBackend({canvas, navigator: navigatorRef, onDeviceLost: (loss) => losses.push(loss)});
assert.equal(backend.format, "bgra8unorm");
assert.equal(backend.resize(320, 180), true);
assert.deepEqual([canvas.width, canvas.height], [320, 180]);
assert.deepEqual(canvas.calls[0], ["configure", {device, format: "bgra8unorm", alphaMode: "premultiplied"}]);
assert.equal(backend.resize(0, 180), false);
assert.equal(backend.clear(0x80402010), true);
assert.equal(backend.uploadTexture(1, 2, 2, new Uint8Array(16).fill(255), 0), true);
assert.equal(backend.uploadTexture(2, 2, 2, new Uint8Array(15), 0), false);
assert.equal(textureWrites.length, 1);
assert.equal(backend.pushClip(4, 2, 8, 8), true);
assert.equal(backend.drawRect(0, 0, 16, 16, 0xff0000ff), true);
assert.equal(backend.popClip(), true);
assert.equal(backend.drawSprite(1, 0, 0, 2, 2, 8, 4, 16, 16, 0x80ffffff, 0), true);
assert.equal(backend.drawSprite(1, 0, 0, 2, 2, 24, 4, 16, 16, 0xffffffff, 0), true);
assert.equal(backend.present(), true);
assert.deepEqual(submissions, [["command-buffer"]]);
assert.equal(writes.length, 2);
assert.deepEqual(draws, [6, 12]);
assert.deepEqual(passes[0].colorAttachments[0].clearValue, {r: 16 / 255, g: 32 / 255, b: 64 / 255, a: 128 / 255});
assert.deepEqual(backend.diagnostic(), {adapter_status: "ready", device_status: "ready", canvas_format: "bgra8unorm", logical_width: 320, logical_height: 180});
resolveLost({reason: "destroyed"});
await Promise.resolve();
assert.equal(backend.isLost(), true);
assert.deepEqual(losses, [{reason: "destroyed"}]);
assert.equal(backend.present(), false);
backend.destroy();
assert.deepEqual(canvas.calls.at(-1), ["unconfigure"]);
assert.equal(submissions.at(-1), "destroy");
await assert.rejects(() => createWebGpuBackend({canvas}), (error) => error instanceof WebGpuBackendError && error.code === "webgpu_unavailable");

const hostCanvas = new FakeCanvas();
const hostDevice = {
  lost: new Promise(() => {}),
  queue: {submit() {}, writeBuffer() {}, writeTexture() {}},
  createShaderModule: () => "shader",
  createRenderPipeline: () => ({getBindGroupLayout: () => "sprite-layout"}),
  createBuffer: () => ({destroy() {}}),
  createTexture: () => ({createView: () => "texture-view", destroy() {}}),
  createSampler: () => "sampler",
  createBindGroup: () => "bind-group",
  createCommandEncoder: () => ({beginRenderPass: () => ({setPipeline() {}, setVertexBuffer() {}, setBindGroup() {}, draw() {}, end() {}}), finish: () => "host-command"}),
};
const host = createBrowserHost({canvas: hostCanvas, navigator: {gpu: {requestAdapter: async () => ({requestDevice: async () => hostDevice}), getPreferredCanvasFormat: () => "rgba8unorm"}}});
assert.deepEqual(await host.initializeWebGpu(64, 32), {adapter_status: "ready", device_status: "ready", canvas_format: "rgba8unorm", logical_width: 64, logical_height: 32});
assert.equal(host.imports.env.up_host_gl_context_create(128, 72), Status.ok);
assert.deepEqual(host.webgpu(), {adapter_status: "ready", device_status: "ready", canvas_format: "rgba8unorm", logical_width: 128, logical_height: 72});
assert.equal(host.imports.env.up_host_gl_clear(0xff000000), Status.ok);
const hostTexture = host.imports.env.up_host_gl_resource_create(1, 0);
new Uint8Array(host.memory.buffer, 0, 16).fill(255);
assert.equal(host.imports.env.up_host_gl_texture_upload(hostTexture, 2, 2, 0, 16, 0), Status.ok);
assert.equal(host.imports.env.up_host_gl_draw_sprite(hostTexture, 0, 0, 2, 2, 4, 5, 8, 9, 0xffffffff, 0), Status.ok);
assert.equal(host.imports.env.up_host_gl_present(0), Status.ok);
assert.equal(host.imports.env.up_host_gl_present(1), Status.unavailable);
host.imports.env.up_host_gl_resource_destroy(1, hostTexture);
host.imports.env.up_host_gl_context_destroy();
assert.equal(host.webgpu(), null);
console.log("browser-webgpu passed");
