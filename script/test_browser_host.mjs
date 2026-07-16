import assert from "node:assert/strict";
import {createBrowserHost, ResourceKind, Status} from "../src/browser/host.mjs";

class FakeWebGl2 {
  ARRAY_BUFFER = 1;
  DYNAMIC_DRAW = 2;
  TEXTURE_2D = 3;
  TEXTURE_MIN_FILTER = 4;
  TEXTURE_MAG_FILTER = 5;
  TEXTURE_WRAP_S = 6;
  TEXTURE_WRAP_T = 7;
  NEAREST = 8;
  CLAMP_TO_EDGE = 9;
  VERTEX_SHADER = 10;
  FRAGMENT_SHADER = 11;
  COMPILE_STATUS = 12;
  LINK_STATUS = 13;
  FLOAT = 14;
  BLEND = 15;
  SRC_ALPHA = 16;
  ONE_MINUS_SRC_ALPHA = 17;
  ONE = 18;
  TRIANGLES = 19;
  COLOR_BUFFER_BIT = 20;
  lost = false;
  calls = [];
  next = 1;

  createBuffer() { return {kind: "buffer", id: this.next++}; }
  createTexture() { return {kind: "texture", id: this.next++}; }
  createProgram() { return {kind: "program", id: this.next++}; }
  createFramebuffer() { return {kind: "framebuffer", id: this.next++}; }
  createShader() { return {kind: "shader", id: this.next++}; }
  deleteBuffer(value) { this.calls.push(["deleteBuffer", value]); }
  deleteTexture(value) { this.calls.push(["deleteTexture", value]); }
  deleteProgram(value) { this.calls.push(["deleteProgram", value]); }
  deleteFramebuffer(value) { this.calls.push(["deleteFramebuffer", value]); }
  deleteShader(value) { this.calls.push(["deleteShader", value]); }
  bindBuffer(...args) { this.calls.push(["bindBuffer", ...args]); }
  bufferData(...args) { this.calls.push(["bufferData", ...args]); }
  bindTexture(...args) { this.calls.push(["bindTexture", ...args]); }
  texParameteri(...args) { this.calls.push(["texParameteri", ...args]); }
  shaderSource(...args) { this.calls.push(["shaderSource", ...args]); }
  compileShader(...args) { this.calls.push(["compileShader", ...args]); }
  getShaderParameter() { return true; }
  getShaderInfoLog() { return ""; }
  attachShader(...args) { this.calls.push(["attachShader", ...args]); }
  linkProgram(...args) { this.calls.push(["linkProgram", ...args]); }
  getProgramParameter() { return true; }
  getProgramInfoLog() { return ""; }
  useProgram(...args) { this.calls.push(["useProgram", ...args]); }
  enableVertexAttribArray(...args) { this.calls.push(["enableVertexAttribArray", ...args]); }
  vertexAttribPointer(...args) { this.calls.push(["vertexAttribPointer", ...args]); }
  enable(...args) { this.calls.push(["enable", ...args]); }
  blendFuncSeparate(...args) { this.calls.push(["blendFuncSeparate", ...args]); }
  drawArrays(...args) { this.calls.push(["drawArrays", ...args]); }
  clearColor(...args) { this.calls.push(["clearColor", ...args]); }
  clear(...args) { this.calls.push(["clear", ...args]); }
  flush(...args) { this.calls.push(["flush", ...args]); }
  isContextLost() { return this.lost; }
}

class FakeCanvas {
  width = 0;
  height = 0;
  listeners = new Map();
  gl = new FakeWebGl2();

  getContext(name) {
    assert.equal(name, "webgl2");
    return this.gl;
  }

  addEventListener(name, callback) {
    this.listeners.set(name, callback);
  }

  removeEventListener(name, callback) {
    if (this.listeners.get(name) === callback) this.listeners.delete(name);
  }

  dispatch(name, event = {preventDefault() { this.prevented = true; }}) {
    this.listeners.get(name)?.(event);
    return event;
  }
}

const canvas = new FakeCanvas();
const host = createBrowserHost({canvas});
const env = host.imports.env;
assert.deepEqual(Object.keys(env).sort(), [
  "up_host_audio_state", "up_host_audio_submit", "up_host_cancel_frame", "up_host_diagnostic_emit",
  "up_host_gl_context_create", "up_host_gl_context_destroy", "up_host_gl_context_lost", "up_host_gl_resource_create", "up_host_gl_resource_destroy",
  "up_host_gl_clear", "up_host_gl_draw_rect", "up_host_gl_draw_line", "up_host_gl_draw_circle", "up_host_gl_draw_triangle", "up_host_gl_present",
  "up_host_input_poll", "up_host_input_read", "up_host_schedule_frame",
  "up_host_storage_read", "up_host_storage_remove", "up_host_storage_write", "up_host_teardown",
].sort());
assert.equal(env.up_host_gl_context_create(320, 180), Status.ok);
assert.equal(canvas.width, 320);
assert.equal(canvas.height, 180);
assert.equal(env.up_host_gl_clear(0xff000000), Status.ok);
assert.equal(env.up_host_gl_draw_rect(1, 2, 3, 4, 0xff0000ff), Status.ok);
assert.equal(env.up_host_gl_draw_line(0, 0, 4, 3, 0xff0000ff), Status.ok);
assert.equal(env.up_host_gl_draw_circle(16, 16, 4, 0xff0000ff), Status.ok);
assert.equal(env.up_host_gl_draw_triangle(1, 1, 4, 1, 2, 3, 0xff0000ff), Status.ok);
assert.deepEqual(canvas.gl.calls.filter(([name]) => name === "drawArrays").map(([, , , count]) => count), [6, 6, 96, 3]);
assert.equal(env.up_host_gl_present(0), Status.ok);
assert.ok(canvas.gl.calls.some(([name]) => name === "flush"));

const buffer = env.up_host_gl_resource_create(ResourceKind.buffer, 64);
const texture = env.up_host_gl_resource_create(ResourceKind.texture, 0);
const program = env.up_host_gl_resource_create(ResourceKind.program, 0);
const framebuffer = env.up_host_gl_resource_create(ResourceKind.framebuffer, 0);
assert.deepEqual([buffer, texture, program, framebuffer], [1, 2, 3, 4]);
assert.equal(host.resourceCount(), 4);
assert.ok(canvas.gl.calls.some(([name, , bytes]) => name === "bufferData" && bytes === 64));
env.up_host_gl_resource_destroy(ResourceKind.texture, texture);
assert.equal(host.resourceCount(), 3);
assert.ok(canvas.gl.calls.some(([name]) => name === "deleteTexture"));

const lost = canvas.dispatch("webglcontextlost");
assert.equal(lost.prevented, true);
assert.equal(env.up_host_gl_context_lost(), 1);
assert.equal(host.resourceCount(), 0);
assert.equal(env.up_host_gl_resource_create(ResourceKind.buffer, 1), 0);
canvas.dispatch("webglcontextrestored");
assert.equal(env.up_host_gl_context_create(64, 32), Status.ok);
env.up_host_teardown();
assert.equal(canvas.listeners.size, 0);
