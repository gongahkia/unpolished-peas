import {createBrowserInput} from "./input.mjs";
import {createBrowserAudio} from "./audio.mjs";
import {createBrowserStorage} from "./storage.mjs";
import {createBrowserArtifacts} from "./artifacts.mjs";

function localStorageOrNull() {
  try {
    return globalThis.localStorage;
  } catch {
    return null;
  }
}

export const AbiVersion = 1;

export const ResourceKind = Object.freeze({
  buffer: 0,
  texture: 1,
  program: 2,
  framebuffer: 3,
});

export const Status = Object.freeze({
  ok: 0,
  invalidArgument: -1,
  unavailable: -2,
  rejected: -3,
});

export function createBrowserHost({
  canvas,
  memory = new WebAssembly.Memory({initial: 32}),
  console: logger = globalThis.console,
  requestAnimationFrame: requestFrame = globalThis.requestAnimationFrame?.bind(globalThis),
  cancelAnimationFrame: cancelFrame = globalThis.cancelAnimationFrame?.bind(globalThis),
  document: documentRef = globalThis.document,
  window: windowRef = globalThis.window,
  navigator: navigatorRef = globalThis.navigator,
  ResizeObserver: ResizeObserverImpl = globalThis.ResizeObserver,
  AudioContext: AudioContextImpl = globalThis.AudioContext ?? globalThis.webkitAudioContext,
  storage: storageRef,
  storageNamespace = "unpolished-peas:v1",
} = {}) {
  let gl = null;
  let contextLost = false;
  let logicalWidth = 0;
  let logicalHeight = 0;
  let primitivePipeline = null;
  let spritePipeline = null;
  let effectPipeline = null;
  let effectTargets = null;
  let spriteBatch = null;
  let clip = null;
  const clipStack = [];
  let blend = 0;
  const blendStack = [];
  let camera = null;
  let presentationMode = 0;
  const effects = [];
  const maxEffects = 8;
  let runtime = null;
  const scheduledFrames = new Map();
  let lifecyclePhase = "idle";
  let lifecycleGeneration = 0;
  let recoveryCount = 0;
  let needsResourceRecovery = false;
  let nextHandle = 1;
  const resources = new Map();
  const input = createBrowserInput({
    canvas,
    document: documentRef,
    window: windowRef,
    navigator: navigatorRef,
    ResizeObserver: ResizeObserverImpl,
    mapCanvas: (x, y) => framebufferToCanvas(x, y, canvas?.width ?? 0, canvas?.height ?? 0),
  });
  const audio = createBrowserAudio({canvas, window: windowRef, AudioContext: AudioContextImpl});
  const storage = createBrowserStorage({storage: storageRef === undefined ? localStorageOrNull() : storageRef, namespace: storageNamespace});
  const artifacts = createBrowserArtifacts({canvas});

  function removeResource(handle, release) {
    const resource = resources.get(handle);
    if (!resource) return;
    if (release && gl && resource.value) {
      switch (resource.kind) {
        case ResourceKind.buffer: gl.deleteBuffer(resource.value); break;
        case ResourceKind.texture: gl.deleteTexture(resource.value); break;
        case ResourceKind.program: gl.deleteProgram(resource.value); break;
        case ResourceKind.framebuffer: gl.deleteFramebuffer(resource.value); break;
      }
    }
    resources.delete(handle);
  }

  function removeAllResources(release) {
    for (const handle of [...resources.keys()]) removeResource(handle, release);
  }

  function invalidateResourceValues() {
    for (const resource of resources.values()) resource.value = null;
  }

  function cancelScheduledFrames() {
    for (const token of scheduledFrames.keys()) cancelFrame?.(token);
    scheduledFrames.clear();
  }

  function scheduleFrame() {
    if (!requestFrame || contextLost || lifecyclePhase === "destroyed") return 0;
    let token = 0;
    token = requestFrame((timestamp) => {
      scheduledFrames.delete(token);
      if (!contextLost) runtime?.up_browser_frame?.(timestamp);
    });
    if (!Number.isInteger(token) || token < 0) return 0;
    scheduledFrames.set(token, true);
    return token;
  }

  function cancelScheduledFrame(token) {
    if (!scheduledFrames.delete(token)) return;
    cancelFrame?.(token);
  }

  function restoreResources() {
    for (const resource of resources.values()) {
      const value = createResourceValue(resource.kind, resource.byteLength);
      if (!value) return false;
      resource.value = value;
      if (resource.kind !== ResourceKind.texture || !resource.pixels) continue;
      gl.bindTexture(gl.TEXTURE_2D, value);
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, resource.sampling === 0 ? gl.NEAREST : gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, resource.sampling === 0 ? gl.NEAREST : gl.LINEAR);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, resource.width, resource.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, resource.pixels);
    }
    return true;
  }

  function releasePrimitivePipeline(release) {
    if (!primitivePipeline) return;
    if (release && gl) {
      gl.deleteBuffer(primitivePipeline.buffer);
      gl.deleteProgram(primitivePipeline.program);
    }
    primitivePipeline = null;
  }

  function releaseSpritePipeline(release) {
    if (!spritePipeline) return;
    if (release && gl) {
      gl.deleteBuffer(spritePipeline.buffer);
      gl.deleteProgram(spritePipeline.program);
    }
    spritePipeline = null;
  }

  function releaseEffectPipeline(release) {
    if (!effectPipeline) return;
    if (release && gl) {
      gl.deleteBuffer(effectPipeline.buffer);
      gl.deleteProgram(effectPipeline.program);
    }
    effectPipeline = null;
  }

  function releaseEffectTargets(release) {
    if (!effectTargets) return;
    if (release && gl) for (const target of [effectTargets.scene, effectTargets.ping]) {
      gl.deleteTexture(target.texture);
      gl.deleteFramebuffer(target.framebuffer);
    }
    effectTargets = null;
  }

  function wasmBytes(pointer, byteLength) {
    if (!Number.isInteger(pointer) || !Number.isInteger(byteLength) || pointer < 0 || byteLength < 0 || pointer > memory.buffer.byteLength - byteLength) return null;
    return new Uint8Array(memory.buffer, pointer, byteLength);
  }

  function compileShader(type, source) {
    const shader = gl.createShader(type);
    if (!shader) return null;
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (gl.getShaderParameter(shader, gl.COMPILE_STATUS)) return shader;
    logger?.error?.(`unpolished-peas browser: WebGL shader compilation failed: ${gl.getShaderInfoLog(shader) ?? "unknown error"}`);
    gl.deleteShader(shader);
    return null;
  }

  function ensurePrimitivePipeline() {
    if (!gl || contextLost) return null;
    if (primitivePipeline) return primitivePipeline;
    const vertex = compileShader(gl.VERTEX_SHADER, `#version 300 es
      layout(location = 0) in vec2 in_position;
      layout(location = 1) in vec4 in_color;
      out vec4 out_color;
      void main() { gl_Position = vec4(in_position, 0.0, 1.0); out_color = in_color; }`);
    if (!vertex) return null;
    const fragment = compileShader(gl.FRAGMENT_SHADER, `#version 300 es
      precision mediump float;
      in vec4 out_color;
      out vec4 fragment_color;
      void main() { fragment_color = out_color; }`);
    if (!fragment) {
      gl.deleteShader(vertex);
      return null;
    }
    const program = gl.createProgram();
    if (!program) {
      gl.deleteShader(vertex);
      gl.deleteShader(fragment);
      return null;
    }
    gl.attachShader(program, vertex);
    gl.attachShader(program, fragment);
    gl.linkProgram(program);
    gl.deleteShader(vertex);
    gl.deleteShader(fragment);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      logger?.error?.(`unpolished-peas browser: WebGL program link failed: ${gl.getProgramInfoLog(program) ?? "unknown error"}`);
      gl.deleteProgram(program);
      return null;
    }
    const buffer = gl.createBuffer();
    if (!buffer) {
      gl.deleteProgram(program);
      return null;
    }
    primitivePipeline = {program, buffer};
    return primitivePipeline;
  }

  function ensureSpritePipeline() {
    if (!gl || contextLost) return null;
    if (spritePipeline) return spritePipeline;
    const vertex = compileShader(gl.VERTEX_SHADER, `#version 300 es
      layout(location = 0) in vec2 in_position;
      layout(location = 1) in vec2 in_uv;
      layout(location = 2) in vec4 in_tint;
      out vec2 out_uv;
      out vec4 out_tint;
      void main() { gl_Position = vec4(in_position, 0.0, 1.0); out_uv = in_uv; out_tint = in_tint; }`);
    if (!vertex) return null;
    const fragment = compileShader(gl.FRAGMENT_SHADER, `#version 300 es
      precision mediump float;
      uniform sampler2D sprite_texture;
      in vec2 out_uv;
      in vec4 out_tint;
      out vec4 fragment_color;
      void main() { fragment_color = texture(sprite_texture, out_uv) * out_tint; }`);
    if (!fragment) {
      gl.deleteShader(vertex);
      return null;
    }
    const program = gl.createProgram();
    if (!program) {
      gl.deleteShader(vertex);
      gl.deleteShader(fragment);
      return null;
    }
    gl.attachShader(program, vertex);
    gl.attachShader(program, fragment);
    gl.linkProgram(program);
    gl.deleteShader(vertex);
    gl.deleteShader(fragment);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      logger?.error?.(`unpolished-peas browser: WebGL sprite link failed: ${gl.getProgramInfoLog(program) ?? "unknown error"}`);
      gl.deleteProgram(program);
      return null;
    }
    const buffer = gl.createBuffer();
    const sampler = gl.getUniformLocation(program, "sprite_texture");
    if (!buffer || sampler === null) {
      if (buffer) gl.deleteBuffer(buffer);
      gl.deleteProgram(program);
      return null;
    }
    spritePipeline = {program, buffer, sampler};
    return spritePipeline;
  }

  function ensureEffectPipeline() {
    if (!gl || contextLost) return null;
    if (effectPipeline) return effectPipeline;
    const vertex = compileShader(gl.VERTEX_SHADER, `#version 300 es
      layout(location = 0) in vec2 in_position;
      layout(location = 1) in vec2 in_uv;
      out vec2 out_uv;
      void main() { gl_Position = vec4(in_position, 0.0, 1.0); out_uv = in_uv; }`);
    if (!vertex) return null;
    const fragment = compileShader(gl.FRAGMENT_SHADER, `#version 300 es
      precision mediump float;
      uniform sampler2D effect_texture;
      uniform float amount;
      in vec2 out_uv;
      out vec4 fragment_color;
      void main() {
        vec4 color = texture(effect_texture, out_uv);
        fragment_color = vec4(mix(color.rgb, vec3(1.0) - color.rgb, amount), color.a);
      }`);
    if (!fragment) {
      gl.deleteShader(vertex);
      return null;
    }
    const program = gl.createProgram();
    if (!program) {
      gl.deleteShader(vertex);
      gl.deleteShader(fragment);
      return null;
    }
    gl.attachShader(program, vertex);
    gl.attachShader(program, fragment);
    gl.linkProgram(program);
    gl.deleteShader(vertex);
    gl.deleteShader(fragment);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      logger?.error?.(`unpolished-peas browser: WebGL effect link failed: ${gl.getProgramInfoLog(program) ?? "unknown error"}`);
      gl.deleteProgram(program);
      return null;
    }
    const buffer = gl.createBuffer();
    const sampler = gl.getUniformLocation(program, "effect_texture");
    const amount = gl.getUniformLocation(program, "amount");
    if (!buffer || sampler === null || amount === null) {
      if (buffer) gl.deleteBuffer(buffer);
      gl.deleteProgram(program);
      return null;
    }
    effectPipeline = {program, buffer, sampler, amount};
    return effectPipeline;
  }

  function appliesEffects() {
    return effects.some(({kind}) => kind === 0);
  }

  function configureEffectTarget(target) {
    gl.bindTexture(gl.TEXTURE_2D, target.texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, logicalWidth, logicalHeight, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.bindFramebuffer(gl.FRAMEBUFFER, target.framebuffer);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, target.texture, 0);
    return gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE;
  }

  function ensureEffectTargets() {
    if (!gl || contextLost || logicalWidth === 0 || logicalHeight === 0) return null;
    if (effectTargets?.width === logicalWidth && effectTargets.height === logicalHeight) return effectTargets;
    releaseEffectTargets(true);
    const scene = {texture: gl.createTexture(), framebuffer: gl.createFramebuffer()};
    const ping = {texture: gl.createTexture(), framebuffer: gl.createFramebuffer()};
    if (!scene.texture || !scene.framebuffer || !ping.texture || !ping.framebuffer) {
      for (const target of [scene, ping]) {
        if (target.texture) gl.deleteTexture(target.texture);
        if (target.framebuffer) gl.deleteFramebuffer(target.framebuffer);
      }
      return null;
    }
    effectTargets = {scene, ping, width: logicalWidth, height: logicalHeight};
    if (!configureEffectTarget(scene) || !configureEffectTarget(ping)) {
      releaseEffectTargets(true);
      return null;
    }
    return effectTargets;
  }

  function bindDrawTarget() {
    if (!appliesEffects()) {
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.viewport(0, 0, canvas.width, canvas.height);
      return true;
    }
    const targets = ensureEffectTargets();
    if (!targets) return false;
    gl.bindFramebuffer(gl.FRAMEBUFFER, targets.scene.framebuffer);
    gl.viewport(0, 0, logicalWidth, logicalHeight);
    return true;
  }

  function colorFloats(color) {
    return [
      (color & 0xff) / 255,
      ((color >>> 8) & 0xff) / 255,
      ((color >>> 16) & 0xff) / 255,
      ((color >>> 24) & 0xff) / 255,
    ];
  }

  function transformPoint(x, y) {
    if (!camera) return [x, y];
    const localX = x - camera.x;
    const localY = y - camera.y;
    const cos = Math.cos(camera.rotation);
    const sin = Math.sin(camera.rotation);
    return [camera.viewportX + camera.viewportWidth / 2 + (cos * localX + sin * localY) * camera.zoom, camera.viewportY + camera.viewportHeight / 2 + (-sin * localX + cos * localY) * camera.zoom];
  }

  function vertexFromCanvas(x, y, color) {
    return [x * 2 / logicalWidth - 1, 1 - y * 2 / logicalHeight, ...color];
  }

  function vertex(x, y, color) {
    return vertexFromCanvas(...transformPoint(x, y), color);
  }

  function quad(ax, ay, bx, by, cx, cy, dx, dy, color) {
    return [...vertex(ax, ay, color), ...vertex(bx, by, color), ...vertex(cx, cy, color), ...vertex(ax, ay, color), ...vertex(cx, cy, color), ...vertex(dx, dy, color)];
  }

  function quadFromCanvas(ax, ay, bx, by, cx, cy, dx, dy, color) {
    return [...vertexFromCanvas(ax, ay, color), ...vertexFromCanvas(bx, by, color), ...vertexFromCanvas(cx, cy, color), ...vertexFromCanvas(ax, ay, color), ...vertexFromCanvas(cx, cy, color), ...vertexFromCanvas(dx, dy, color)];
  }

  function applyRenderState() {
    if (clip) {
      const x = Math.max(0, Math.min(logicalWidth, clip.x));
      const y = Math.max(0, Math.min(logicalHeight, clip.y));
      const right = Math.max(x, Math.min(logicalWidth, clip.x + clip.width));
      const bottom = Math.max(y, Math.min(logicalHeight, clip.y + clip.height));
      gl.enable(gl.SCISSOR_TEST);
      gl.scissor(x, logicalHeight - bottom, right - x, bottom - y);
    } else gl.disable(gl.SCISSOR_TEST);
    gl.enable(gl.BLEND);
    if (blend === 0) gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    else gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
  }

  function drawVertices(vertices) {
    if (!gl) return Status.unavailable;
    if (contextLost || logicalWidth === 0 || logicalHeight === 0) return Status.rejected;
    const spriteStatus = flushSprites();
    if (spriteStatus !== Status.ok) return spriteStatus;
    if (!bindDrawTarget()) return Status.rejected;
    const pipeline = ensurePrimitivePipeline();
    if (!pipeline) return Status.rejected;
    gl.useProgram(pipeline.program);
    gl.bindBuffer(gl.ARRAY_BUFFER, pipeline.buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(vertices), gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 24, 0);
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 4, gl.FLOAT, false, 24, 8);
    applyRenderState();
    gl.drawArrays(gl.TRIANGLES, 0, vertices.length / 6);
    return Status.ok;
  }

  function spriteVertex(x, y, u, v, color) {
    const point = transformPoint(x, y);
    return [point[0] * 2 / logicalWidth - 1, 1 - point[1] * 2 / logicalHeight, u, v, ...color];
  }

  function flushSprites() {
    if (!spriteBatch) return Status.ok;
    if (!gl) return Status.unavailable;
    if (contextLost) return Status.rejected;
    if (!bindDrawTarget()) return Status.rejected;
    const pipeline = ensureSpritePipeline();
    if (!pipeline) return Status.rejected;
    gl.useProgram(pipeline.program);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, spriteBatch.texture.value);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, spriteBatch.sampling === 0 ? gl.NEAREST : gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, spriteBatch.sampling === 0 ? gl.NEAREST : gl.LINEAR);
    gl.bindBuffer(gl.ARRAY_BUFFER, pipeline.buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(spriteBatch.vertices), gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 32, 0);
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 2, gl.FLOAT, false, 32, 8);
    gl.enableVertexAttribArray(2);
    gl.vertexAttribPointer(2, 4, gl.FLOAT, false, 32, 16);
    applyRenderState();
    gl.uniform1i(pipeline.sampler, 0);
    gl.drawArrays(gl.TRIANGLES, 0, spriteBatch.vertices.length / 8);
    spriteBatch = null;
    return Status.ok;
  }

  function uploadTexture(handle, width, height, source, byteLength, sampling) {
    const texture = resources.get(handle);
    const expectedByteLength = width * height * 4;
    const pixels = wasmBytes(source, byteLength);
    if (!texture || texture.kind !== ResourceKind.texture || width === 0 || height === 0 || expectedByteLength !== byteLength || !pixels || sampling > 1) return Status.invalidArgument;
    if (!gl) return Status.unavailable;
    if (contextLost) return Status.rejected;
    if (spriteBatch?.handle === handle) {
      const status = flushSprites();
      if (status !== Status.ok) return status;
    }
    gl.bindTexture(gl.TEXTURE_2D, texture.value);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, sampling === 0 ? gl.NEAREST : gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, sampling === 0 ? gl.NEAREST : gl.LINEAR);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
    texture.width = width;
    texture.height = height;
    texture.sampling = sampling;
    texture.pixels = pixels.slice();
    return Status.ok;
  }

  function drawSprite(handle, sourceX, sourceY, sourceWidth, sourceHeight, x, y, width, height, color, sampling) {
    const texture = resources.get(handle);
    if (!texture || texture.kind !== ResourceKind.texture || !texture.width || !texture.height || sourceWidth === 0 || sourceHeight === 0 || width <= 0 || height <= 0 || sourceX > texture.width - sourceWidth || sourceY > texture.height - sourceHeight || sampling > 1) return Status.invalidArgument;
    if (!gl) return Status.unavailable;
    if (contextLost) return Status.rejected;
    if (spriteBatch && (spriteBatch.handle !== handle || spriteBatch.sampling !== sampling)) {
      const status = flushSprites();
      if (status !== Status.ok) return status;
    }
    spriteBatch ??= {handle, texture, sampling, vertices: []};
    const u0 = sourceX / texture.width;
    const v0 = sourceY / texture.height;
    const u1 = (sourceX + sourceWidth) / texture.width;
    const v1 = (sourceY + sourceHeight) / texture.height;
    const rgba = colorFloats(color);
    spriteBatch.vertices.push(
      ...spriteVertex(x, y, u0, v0, rgba), ...spriteVertex(x + width, y, u1, v0, rgba), ...spriteVertex(x + width, y + height, u1, v1, rgba),
      ...spriteVertex(x, y, u0, v0, rgba), ...spriteVertex(x + width, y + height, u1, v1, rgba), ...spriteVertex(x, y + height, u0, v1, rgba),
    );
    return Status.ok;
  }

  const glyphs = Object.freeze({
    0: [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],
    1: [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
    2: [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],
    3: [0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110],
    4: [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
    5: [0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110],
    6: [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
    7: [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
    8: [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
    9: [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100],
    A: [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
    B: [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110],
    C: [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110],
    D: [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110],
    E: [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111],
    F: [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000],
    G: [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110],
    H: [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
    I: [0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
    J: [0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100],
    K: [0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001],
    L: [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111],
    M: [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001],
    N: [0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001],
    O: [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
    P: [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000],
    Q: [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101],
    R: [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001],
    S: [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110],
    T: [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100],
    U: [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
    V: [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100],
    W: [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010],
    X: [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001],
    Y: [0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100],
    Z: [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111],
    "-": [0, 0, 0, 0b11111, 0, 0, 0],
    _: [0, 0, 0, 0, 0, 0, 0b11111],
    ".": [0, 0, 0, 0, 0, 0b01100, 0b01100],
    ":": [0, 0b01100, 0b01100, 0, 0b01100, 0b01100, 0],
    "/": [0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000],
  });

  function drawText(source, byteLength, x, y, color) {
    const bytes = wasmBytes(source, byteLength);
    if (!bytes) return Status.invalidArgument;
    let cursorX = x;
    let cursorY = y;
    for (const byte of bytes) {
      if (byte === 10) {
        cursorX = x;
        cursorY += 8;
        continue;
      }
      if (byte === 32) {
        cursorX += 6;
        continue;
      }
      const char = String.fromCharCode(byte).toUpperCase();
      const rows = glyphs[char] ?? [0b11111, 0b10001, 0b00110, 0b00100, 0b00110, 0b10001, 0b11111];
      for (let row = 0; row < 7; row += 1) for (let column = 0; column < 5; column += 1) if ((rows[row] & (1 << (4 - column))) !== 0) {
        const status = drawRect(cursorX + column, cursorY + row, 1, 1, color);
        if (status !== Status.ok) return status;
      }
      cursorX += 6;
    }
    return Status.ok;
  }

  function clear(color) {
    if (!gl) return Status.unavailable;
    if (contextLost) return Status.rejected;
    spriteBatch = null;
    if (!bindDrawTarget()) return Status.rejected;
    gl.disable(gl.SCISSOR_TEST);
    gl.clearColor(...colorFloats(color));
    gl.clear(gl.COLOR_BUFFER_BIT);
    return Status.ok;
  }

  function drawRect(x, y, width, height, color) {
    if (width <= 0 || height <= 0) return Status.ok;
    return drawVertices(quad(x, y, x + width, y, x + width, y + height, x, y + height, colorFloats(color)));
  }

  function drawLine(x0, y0, x1, y1, color) {
    const from = transformPoint(x0, y0);
    const to = transformPoint(x1, y1);
    const dx = to[0] - from[0];
    const dy = to[1] - from[1];
    const length = Math.hypot(dx, dy);
    if (length === 0) return drawVertices(quadFromCanvas(from[0] - 0.5, from[1] - 0.5, from[0] + 0.5, from[1] - 0.5, from[0] + 0.5, from[1] + 0.5, from[0] - 0.5, from[1] + 0.5, colorFloats(color)));
    const offsetX = -dy / length * 0.5;
    const offsetY = dx / length * 0.5;
    return drawVertices(quadFromCanvas(from[0] + offsetX, from[1] + offsetY, to[0] + offsetX, to[1] + offsetY, to[0] - offsetX, to[1] - offsetY, from[0] - offsetX, from[1] - offsetY, colorFloats(color)));
  }

  function drawCircle(x, y, radius, color) {
    if (radius <= 0) return Status.ok;
    const rgba = colorFloats(color);
    const vertices = [];
    for (let index = 0; index < 32; index += 1) {
      const a = index * Math.PI * 2 / 32;
      const b = (index + 1) * Math.PI * 2 / 32;
      vertices.push(...vertex(x, y, rgba), ...vertex(x + Math.cos(a) * radius, y + Math.sin(a) * radius, rgba), ...vertex(x + Math.cos(b) * radius, y + Math.sin(b) * radius, rgba));
    }
    return drawVertices(vertices);
  }

  function drawTriangle(ax, ay, bx, by, cx, cy, color) {
    const rgba = colorFloats(color);
    return drawVertices([...vertex(ax, ay, rgba), ...vertex(bx, by, rgba), ...vertex(cx, cy, rgba)]);
  }

  function drawEffectPass(texture, amount) {
    const pipeline = ensureEffectPipeline();
    if (!pipeline) return false;
    const vertices = new Float32Array([
      -1, 1, 0, 1, 1, 1, 1, 1, 1, -1, 1, 0,
      -1, 1, 0, 1, 1, -1, 1, 0, -1, -1, 0, 0,
    ]);
    gl.useProgram(pipeline.program);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.bindBuffer(gl.ARRAY_BUFFER, pipeline.buffer);
    gl.bufferData(gl.ARRAY_BUFFER, vertices, gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 16, 0);
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 2, gl.FLOAT, false, 16, 8);
    gl.disable(gl.SCISSOR_TEST);
    gl.disable(gl.BLEND);
    gl.uniform1i(pipeline.sampler, 0);
    gl.uniform1f(pipeline.amount, amount);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
    return true;
  }

  function composeEffects(mode) {
    const targets = ensureEffectTargets();
    if (!targets) return Status.rejected;
    let source = targets.scene;
    for (const effect of effects) {
      if (effect.kind === 1) continue;
      const target = source === targets.scene ? targets.ping : targets.scene;
      gl.bindFramebuffer(gl.FRAMEBUFFER, target.framebuffer);
      gl.viewport(0, 0, logicalWidth, logicalHeight);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      if (!drawEffectPass(source.texture, effect.amount)) return Status.rejected;
      source = target;
    }
    const destination = presentationDestination(mode, logicalWidth, logicalHeight, canvas.width, canvas.height);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.disable(gl.SCISSOR_TEST);
    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.viewport(destination.x, canvas.height - destination.y - destination.height, destination.width, destination.height);
    if (!drawEffectPass(source.texture, 0)) return Status.rejected;
    return Status.ok;
  }

  function present(mode) {
    if (!gl) return Status.unavailable;
    if (contextLost || mode > 2 || clipStack.length !== 0 || blendStack.length !== 0) return Status.rejected;
    const status = flushSprites();
    if (status !== Status.ok) return status;
    presentationMode = mode;
    if (appliesEffects()) {
      const effectStatus = composeEffects(mode);
      if (effectStatus !== Status.ok) return effectStatus;
      gl.flush();
      return Status.ok;
    }
    const destination = presentationDestination(mode, logicalWidth, logicalHeight, canvas.width, canvas.height);
    gl.viewport(destination.x, canvas.height - destination.y - destination.height, destination.width, destination.height);
    gl.flush();
    return Status.ok;
  }

  function clearEffects() {
    if (!gl) return Status.unavailable;
    if (contextLost) return Status.rejected;
    effects.length = 0;
    return Status.ok;
  }

  function appendEffect(kind, amount) {
    if (!Number.isInteger(kind) || (kind !== 0 && kind !== 1) || !Number.isFinite(amount) || amount < 0 || amount > 1) return Status.invalidArgument;
    if (!gl) return Status.unavailable;
    if (contextLost || effects.length === maxEffects) return Status.rejected;
    effects.push({kind, amount});
    return Status.ok;
  }

  function pushClip(x, y, width, height) {
    if (width < 0 || height < 0) return Status.invalidArgument;
    const status = flushSprites();
    if (status !== Status.ok) return status;
    clipStack.push(clip);
    if (!clip) clip = {x, y, width, height};
    else {
      const left = Math.max(clip.x, x);
      const top = Math.max(clip.y, y);
      const right = Math.min(clip.x + clip.width, x + width);
      const bottom = Math.min(clip.y + clip.height, y + height);
      clip = {x: left, y: top, width: Math.max(0, right - left), height: Math.max(0, bottom - top)};
    }
    return Status.ok;
  }

  function popClip() {
    if (clipStack.length === 0) return Status.rejected;
    const status = flushSprites();
    if (status !== Status.ok) return status;
    clip = clipStack.pop();
    return Status.ok;
  }

  function pushBlend(mode) {
    if (mode > 1) return Status.invalidArgument;
    const status = flushSprites();
    if (status !== Status.ok) return status;
    blendStack.push(blend);
    blend = mode;
    return Status.ok;
  }

  function popBlend() {
    if (blendStack.length === 0) return Status.rejected;
    const status = flushSprites();
    if (status !== Status.ok) return status;
    blend = blendStack.pop();
    return Status.ok;
  }

  function setCamera(enabled, x, y, zoom, rotation, viewportX, viewportY, viewportWidth, viewportHeight) {
    if (enabled === 0) {
      camera = null;
      return Status.ok;
    }
    if (enabled !== 1 || !Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(zoom) || !Number.isFinite(rotation) || !Number.isFinite(viewportX) || !Number.isFinite(viewportY) || !Number.isFinite(viewportWidth) || !Number.isFinite(viewportHeight) || zoom <= 0 || viewportWidth <= 0 || viewportHeight <= 0) return Status.invalidArgument;
    const status = flushSprites();
    if (status !== Status.ok) return status;
    camera = {x, y, zoom, rotation, viewportX, viewportY, viewportWidth, viewportHeight};
    return Status.ok;
  }

  function presentationDestination(mode, canvasWidth, canvasHeight, framebufferWidth, framebufferHeight) {
    if (canvasWidth <= 0 || canvasHeight <= 0 || framebufferWidth <= 0 || framebufferHeight <= 0) return {x: 0, y: 0, width: 0, height: 0};
    if (mode === 0) return {x: 0, y: 0, width: framebufferWidth, height: framebufferHeight};
    let scale = Math.min(framebufferWidth / canvasWidth, framebufferHeight / canvasHeight);
    if (mode === 2 && scale >= 1) scale = Math.floor(scale);
    const width = canvasWidth * scale;
    const height = canvasHeight * scale;
    return {x: (framebufferWidth - width) / 2, y: (framebufferHeight - height) / 2, width, height};
  }

  function framebufferToCanvas(x, y, framebufferWidth, framebufferHeight, mode = presentationMode) {
    const destination = presentationDestination(mode, logicalWidth, logicalHeight, framebufferWidth, framebufferHeight);
    if (destination.width <= 0 || destination.height <= 0 || x < destination.x || y < destination.y || x >= destination.x + destination.width || y >= destination.y + destination.height) return null;
    return {x: (x - destination.x) * logicalWidth / destination.width, y: (y - destination.y) * logicalHeight / destination.height};
  }

  function createContext(width, height) {
    if (!canvas || width === 0 || height === 0) return Status.invalidArgument;
    if (contextLost) return Status.rejected;
    canvas.width = width;
    canvas.height = height;
    logicalWidth = width;
    logicalHeight = height;
    gl ??= canvas.getContext("webgl2", {alpha: true, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: false});
    if (!gl) return Status.unavailable;
    if (gl.isContextLost?.()) {
      contextLost = true;
      needsResourceRecovery = true;
      invalidateResourceValues();
      releasePrimitivePipeline(false);
      releaseSpritePipeline(false);
      releaseEffectPipeline(false);
      releaseEffectTargets(false);
      lifecyclePhase = "context_lost";
      return Status.rejected;
    }
    if (needsResourceRecovery) {
      if (!restoreResources()) {
        invalidateResourceValues();
        lifecyclePhase = "recovery_failed";
        return Status.rejected;
      }
      needsResourceRecovery = false;
      recoveryCount += 1;
      lifecyclePhase = "recovered";
    } else lifecyclePhase = "active";
    if (effectTargets && (effectTargets.width !== width || effectTargets.height !== height)) releaseEffectTargets(true);
    return Status.ok;
  }

  function createResourceValue(kind, byteLength) {
    let value = null;
    switch (kind) {
      case ResourceKind.buffer:
        value = gl.createBuffer();
        if (value) {
          gl.bindBuffer(gl.ARRAY_BUFFER, value);
          gl.bufferData(gl.ARRAY_BUFFER, byteLength, gl.DYNAMIC_DRAW);
        }
        break;
      case ResourceKind.texture:
        value = gl.createTexture();
        if (value) {
          gl.bindTexture(gl.TEXTURE_2D, value);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        }
        break;
      case ResourceKind.program:
        value = gl.createProgram();
        break;
      case ResourceKind.framebuffer:
        value = gl.createFramebuffer();
        break;
    }
    return value;
  }

  function createResource(kind, byteLength) {
    if (!gl || contextLost || !Number.isInteger(byteLength) || byteLength < 0) return 0;
    const value = createResourceValue(kind, byteLength);
    if (!value) return 0;
    const handle = nextHandle;
    nextHandle += 1;
    resources.set(handle, {kind, value, byteLength});
    return handle;
  }

  function onContextLost(event) {
    event.preventDefault();
    contextLost = true;
    needsResourceRecovery = true;
    lifecycleGeneration += 1;
    lifecyclePhase = "context_lost";
    cancelScheduledFrames();
    invalidateResourceValues();
    releasePrimitivePipeline(false);
    releaseSpritePipeline(false);
    releaseEffectPipeline(false);
    releaseEffectTargets(false);
    spriteBatch = null;
  }

  function onContextRestored() {
    contextLost = false;
    gl = null;
    lifecyclePhase = "restoring";
    if (logicalWidth === 0 || logicalHeight === 0 || createContext(logicalWidth, logicalHeight) !== Status.ok) return;
    runtime?.up_browser_resize?.(logicalWidth, logicalHeight);
    scheduleFrame();
  }

  canvas?.addEventListener("webglcontextlost", onContextLost);
  canvas?.addEventListener("webglcontextrestored", onContextRestored);

  const env = {
    up_host_schedule_frame: scheduleFrame,
    up_host_cancel_frame: cancelScheduledFrame,
    up_host_gl_context_create: createContext,
    up_host_gl_context_destroy: () => {
      cancelScheduledFrames();
      removeAllResources(!contextLost);
      releasePrimitivePipeline(!contextLost);
      releaseSpritePipeline(!contextLost);
      releaseEffectPipeline(!contextLost);
      releaseEffectTargets(!contextLost);
      spriteBatch = null;
      lifecyclePhase = "destroyed";
      gl = null;
    },
    up_host_gl_resource_create: createResource,
    up_host_gl_resource_destroy: (kind, handle) => {
      const resource = resources.get(handle);
      if (!resource || resource.kind !== kind) return;
      if (spriteBatch?.handle === handle) flushSprites();
      removeResource(handle, true);
    },
    up_host_gl_context_lost: () => Number(contextLost || gl?.isContextLost?.()),
    up_host_gl_clear: clear,
    up_host_gl_draw_rect: drawRect,
    up_host_gl_draw_line: drawLine,
    up_host_gl_draw_circle: drawCircle,
    up_host_gl_draw_triangle: drawTriangle,
    up_host_gl_present: present,
    up_host_gl_texture_upload: uploadTexture,
    up_host_gl_draw_sprite: drawSprite,
    up_host_gl_flush_sprites: flushSprites,
    up_host_gl_draw_text: drawText,
    up_host_gl_push_clip: pushClip,
    up_host_gl_pop_clip: popClip,
    up_host_gl_push_blend: pushBlend,
    up_host_gl_pop_blend: popBlend,
    up_host_gl_set_camera: setCamera,
    up_host_gl_effect_clear: clearEffects,
    up_host_gl_effect_append: appendEffect,
    up_host_input_poll: input.poll,
    up_host_input_read: (destination, capacity) => input.read(destination, capacity, memory),
    up_host_audio_state: audio.state,
    up_host_audio_submit: (source, byteLength) => audio.submit(memory, source, byteLength),
    up_host_storage_read: (key, keyLength, destination, capacity) => storage.read(memory, key, keyLength, destination, capacity),
    up_host_storage_write: (key, keyLength, source, byteLength) => storage.write(memory, key, keyLength, source, byteLength),
    up_host_storage_remove: (key, keyLength) => storage.remove(memory, key, keyLength),
    up_host_diagnostic_emit: (source, byteLength) => { artifacts.emit(memory, source, byteLength); },
    up_host_teardown: () => {
      cancelScheduledFrames();
      removeAllResources(!contextLost);
      releasePrimitivePipeline(!contextLost);
      releaseSpritePipeline(!contextLost);
      releaseEffectPipeline(!contextLost);
      releaseEffectTargets(!contextLost);
      spriteBatch = null;
      canvas?.removeEventListener("webglcontextlost", onContextLost);
      canvas?.removeEventListener("webglcontextrestored", onContextRestored);
      input.teardown();
      audio.teardown();
      lifecyclePhase = "destroyed";
      runtime = null;
      gl = null;
    },
  };

  return {
    abiVersion: AbiVersion,
    imports: {env: {...env, memory}},
    memory,
    resourceCount: () => resources.size,
    context: () => gl,
    attachRuntime: (exports) => {
      if (!exports || typeof exports.up_browser_frame !== "function") return false;
      runtime = exports;
      return true;
    },
    lifecycle: () => ({phase: lifecyclePhase, generation: lifecycleGeneration, recoveries: recoveryCount, scheduledFrames: scheduledFrames.size}),
    input: () => input.snapshot(),
    setActionBindings: input.setActions,
    actionValues: input.actionValues,
    activateAudio: audio.activate,
    audio: audio.diagnostic,
    storage: storage.diagnostic,
    storageKey: storage.key,
    captureFrame: artifacts.captureFrame,
    recordTrace: artifacts.recordTrace,
    recordCommand: artifacts.recordCommand,
    artifacts: artifacts.snapshot,
    framebufferToCanvas,
    diagnostic: (message) => logger?.error?.(`unpolished-peas browser: ${message}`),
  };
}
