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
  LINEAR = 10;
  VERTEX_SHADER = 11;
  FRAGMENT_SHADER = 12;
  COMPILE_STATUS = 13;
  LINK_STATUS = 14;
  FLOAT = 15;
  BLEND = 16;
  SRC_ALPHA = 17;
  ONE_MINUS_SRC_ALPHA = 18;
  ONE = 19;
  TRIANGLES = 20;
  COLOR_BUFFER_BIT = 21;
  TEXTURE0 = 22;
  UNPACK_ALIGNMENT = 23;
  RGBA = 24;
  UNSIGNED_BYTE = 25;
  SCISSOR_TEST = 26;
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
  disable(...args) { this.calls.push(["disable", ...args]); }
  scissor(...args) { this.calls.push(["scissor", ...args]); }
  viewport(...args) { this.calls.push(["viewport", ...args]); }
  pixelStorei(...args) { this.calls.push(["pixelStorei", ...args]); }
  texImage2D(...args) { this.calls.push(["texImage2D", ...args]); }
  activeTexture(...args) { this.calls.push(["activeTexture", ...args]); }
  getUniformLocation() { return 0; }
  uniform1i(...args) { this.calls.push(["uniform1i", ...args]); }
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
  "up_host_gl_texture_upload", "up_host_gl_draw_sprite", "up_host_gl_flush_sprites", "up_host_gl_draw_text",
  "up_host_gl_push_clip", "up_host_gl_pop_clip", "up_host_gl_push_blend", "up_host_gl_pop_blend", "up_host_gl_set_camera",
  "up_host_input_poll", "up_host_input_read", "up_host_schedule_frame",
  "up_host_storage_read", "up_host_storage_remove", "up_host_storage_write", "up_host_teardown", "memory",
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
assert.equal(env.up_host_gl_push_clip(8, 4, 16, 12), Status.ok);
assert.equal(env.up_host_gl_push_clip(12, 8, 16, 12), Status.ok);
assert.equal(env.up_host_gl_push_blend(1), Status.ok);
assert.equal(env.up_host_gl_draw_rect(0, 0, 32, 32, 0xffffffff), Status.ok);
assert.ok(canvas.gl.calls.some(([name, x, y, width, height]) => name === "scissor" && x === 12 && y === 164 && width === 12 && height === 8));
assert.ok(canvas.gl.calls.some(([name, , destination]) => name === "blendFuncSeparate" && destination === canvas.gl.ONE));
assert.equal(env.up_host_gl_pop_blend(), Status.ok);
assert.equal(env.up_host_gl_pop_clip(), Status.ok);
assert.equal(env.up_host_gl_pop_clip(), Status.ok);
assert.equal(env.up_host_gl_set_camera(1, 0, 0, 2, 0, 0, 0, 64, 32), Status.ok);
assert.equal(env.up_host_gl_draw_rect(0, 0, 1, 1, 0xffffffff), Status.ok);
const cameraVertices = canvas.gl.calls.filter(([name]) => name === "bufferData").at(-1)[2];
assert.ok(Math.abs(cameraVertices[0] + 0.8) < 0.0001);
assert.ok(Math.abs(cameraVertices[1] - (1 - 32 / 180)) < 0.0001);
assert.equal(env.up_host_gl_set_camera(0, 0, 0, 0, 0, 0, 0, 0, 0), Status.ok);
assert.deepEqual(host.framebufferToCanvas(500, 400, 1000, 800, 2), {x: 160, y: 90});
assert.equal(host.framebufferToCanvas(10, 10, 1000, 800, 2), null);
assert.equal(env.up_host_gl_present(0), Status.ok);
assert.ok(canvas.gl.calls.some(([name]) => name === "flush"));

const buffer = env.up_host_gl_resource_create(ResourceKind.buffer, 64);
const texture = env.up_host_gl_resource_create(ResourceKind.texture, 0);
const program = env.up_host_gl_resource_create(ResourceKind.program, 0);
const framebuffer = env.up_host_gl_resource_create(ResourceKind.framebuffer, 0);
assert.deepEqual([buffer, texture, program, framebuffer], [1, 2, 3, 4]);
assert.equal(host.resourceCount(), 4);
assert.ok(canvas.gl.calls.some(([name, , bytes]) => name === "bufferData" && bytes === 64));
new Uint8Array(host.memory.buffer, 32, 16).fill(255);
assert.equal(env.up_host_gl_texture_upload(texture, 2, 2, 32, 16, 1), Status.ok);
const beforeSprites = canvas.gl.calls.filter(([name]) => name === "drawArrays").length;
assert.equal(env.up_host_gl_draw_sprite(texture, 0, 0, 1, 1, 4, 5, 8, 9, 0xffffffff, 1), Status.ok);
assert.equal(env.up_host_gl_draw_sprite(texture, 1, 1, 1, 1, 12, 5, 8, 9, 0xffffffff, 1), Status.ok);
assert.equal(env.up_host_gl_flush_sprites(), Status.ok);
assert.deepEqual(canvas.gl.calls.filter(([name]) => name === "drawArrays").slice(beforeSprites).map(([, , , count]) => count), [12]);
new Uint8Array(host.memory.buffer, 0, 1).set([65]);
const beforeText = canvas.gl.calls.filter(([name]) => name === "drawArrays").length;
assert.equal(env.up_host_gl_draw_text(0, 1, 20, 20, 0xffffffff), Status.ok);
assert.ok(canvas.gl.calls.filter(([name]) => name === "drawArrays").length > beforeText);
assert.equal(env.up_host_gl_texture_upload(texture, 2, 2, 32, 16, 0), Status.ok);
assert.equal(canvas.gl.calls.filter(([name]) => name === "texImage2D").length, 2);
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
