import {Status} from "./host.mjs";

export const rendererContractTolerance = 1;

function fail(message) {
  throw new Error(`renderer contract fixture invalid: ${message}`);
}

function integer(value, name) {
  if (!Number.isInteger(value)) fail(name);
  return value;
}

function color(value) {
  if (!value || ![value.r, value.g, value.b, value.a].every((channel) => Number.isInteger(channel) && channel >= 0 && channel <= 255)) fail("color");
  return value;
}

function pack(value) {
  return (value.r | (value.g << 8) | (value.b << 16) | (value.a << 24)) >>> 0;
}

function intersect(a, b) {
  const x = Math.max(a.x, b.x);
  const y = Math.max(a.y, b.y);
  return {x, y, w: Math.max(0, Math.min(a.x + a.w, b.x + b.w) - x), h: Math.max(0, Math.min(a.y + a.h, b.y + b.h) - y)};
}

function camera(value) {
  if (!value || typeof value.enabled !== "boolean") fail("camera");
  if (!value.enabled) return value;
  if (![value.x, value.y, value.zoom, value.rotation, value.viewport_x, value.viewport_y, value.viewport_w, value.viewport_h].every(Number.isFinite) || value.zoom <= 0 || value.viewport_w <= 0 || value.viewport_h <= 0 || value.rotation !== 0) fail("camera transform");
  return value;
}

function assetMap(fixture) {
  if (!Array.isArray(fixture.assets)) fail("assets");
  const assets = new Map();
  for (const asset of fixture.assets) {
    const byteLength = asset?.width * asset?.height * 4;
    if (!asset || typeof asset.id !== "string" || asset.id.length === 0 || !Number.isInteger(asset.width) || !Number.isInteger(asset.height) || asset.width <= 0 || asset.height <= 0 || !Number.isSafeInteger(byteLength) || !Array.isArray(asset.rgba) || asset.rgba.length !== byteLength || !asset.rgba.every((channel) => Number.isInteger(channel) && channel >= 0 && channel <= 255) || assets.has(asset.id)) fail("asset");
    assets.set(asset.id, asset);
  }
  return assets;
}

export function validateRendererContract(fixture) {
  if (fixture?.schema_version !== 1 || fixture.fixture_version !== "v1" || fixture.width !== 64 || fixture.height !== 32 || fixture.tolerance?.per_channel !== rendererContractTolerance || !Array.isArray(fixture.operations)) fail("schema");
  const assets = assetMap(fixture);
  let cameraActive = false;
  let clips = 0;
  let blends = 0;
  for (const operation of fixture.operations) {
    if (!operation || typeof operation.op !== "string") fail("operation");
    switch (operation.op) {
      case "clear": color(operation.color); break;
      case "rect":
        integer(operation.x, "rect x"); integer(operation.y, "rect y");
        if (integer(operation.w, "rect w") <= 0 || integer(operation.h, "rect h") <= 0) fail("rect size");
        color(operation.color);
        break;
      case "image":
        if (!assets.has(operation.asset)) fail("image asset");
        integer(operation.x, "image x"); integer(operation.y, "image y");
        break;
      case "text":
        if (typeof operation.value !== "string" || operation.value.length === 0) fail("text value");
        integer(operation.x, "text x"); integer(operation.y, "text y");
        color(operation.color);
        break;
      case "push_clip":
        integer(operation.x, "clip x"); integer(operation.y, "clip y");
        if (integer(operation.w, "clip w") < 0 || integer(operation.h, "clip h") < 0) fail("clip size");
        clips += 1;
        break;
      case "pop_clip": if (clips-- <= 0) fail("clip stack"); break;
      case "push_blend": if (integer(operation.mode, "blend mode") < 0 || operation.mode > 1) fail("blend mode"); blends += 1; break;
      case "pop_blend": if (blends-- <= 0) fail("blend stack"); break;
      case "set_camera": {
        const value = camera(operation.camera);
        cameraActive = value.enabled;
        break;
      }
      default: fail(`operation ${operation.op}`);
    }
  }
  if (cameraActive || clips !== 0 || blends !== 0) fail("unbalanced state");
  return fixture;
}

function call(runtime, host, commands, name, ...args) {
  const command = {name, args};
  commands.push(command);
  host.recordCommand?.(command);
  if (runtime[name](...args) !== Status.ok) throw new Error(`renderer contract command failed: ${name}`);
}

function uploadContractAssets(runtime, host, commands, fixture) {
  const assets = assetMap(fixture);
  const handles = new Map();
  let offset = 1024;
  for (const asset of assets.values()) {
    if (!host?.memory?.buffer || offset > host.memory.buffer.byteLength - asset.rgba.length) fail("asset memory");
    new Uint8Array(host.memory.buffer, offset, asset.rgba.length).set(asset.rgba);
    const command = {name: "up_browser_gl_resource_create", args: [1, 0]};
    commands.push(command);
    host.recordCommand?.(command);
    const handle = runtime.up_browser_gl_resource_create(1, 0);
    if (!Number.isInteger(handle) || handle <= 0) fail("asset texture");
    call(runtime, host, commands, "up_browser_texture_upload", handle, asset.width, asset.height, offset, asset.rgba.length, 0);
    handles.set(asset.id, {asset, handle});
    offset += asset.rgba.length;
  }
  return handles;
}

export function runRendererContract(runtime, host, fixture) {
  validateRendererContract(fixture);
  const commands = [];
  call(runtime, host, commands, "up_browser_gl_context_create", fixture.width, fixture.height);
  const assets = uploadContractAssets(runtime, host, commands, fixture);
  let textOffset = 32768;
  for (const operation of fixture.operations) {
    switch (operation.op) {
      case "clear": call(runtime, host, commands, "up_browser_clear", pack(operation.color)); break;
      case "rect": call(runtime, host, commands, "up_browser_draw_rect", operation.x, operation.y, operation.w, operation.h, pack(operation.color)); break;
      case "image": {
        const asset = assets.get(operation.asset);
        if (!asset) fail("image asset");
        call(runtime, host, commands, "up_browser_draw_sprite", asset.handle, 0, 0, asset.asset.width, asset.asset.height, operation.x, operation.y, asset.asset.width, asset.asset.height, 0xffffffff, 0);
        break;
      }
      case "text": {
        const bytes = new TextEncoder().encode(operation.value);
        if (!host?.memory?.buffer || textOffset > host.memory.buffer.byteLength - bytes.length) fail("text memory");
        new Uint8Array(host.memory.buffer, textOffset, bytes.length).set(bytes);
        call(runtime, host, commands, "up_browser_draw_text", textOffset, bytes.length, operation.x, operation.y, pack(operation.color));
        textOffset += bytes.length;
        break;
      }
      case "push_clip": call(runtime, host, commands, "up_browser_push_clip", operation.x, operation.y, operation.w, operation.h); break;
      case "pop_clip": call(runtime, host, commands, "up_browser_pop_clip"); break;
      case "push_blend": call(runtime, host, commands, "up_browser_push_blend", operation.mode); break;
      case "pop_blend": call(runtime, host, commands, "up_browser_pop_blend"); break;
      case "set_camera": {
        const value = operation.camera;
        call(runtime, host, commands, "up_browser_set_camera", value.enabled ? 1 : 0, value.x ?? 0, value.y ?? 0, value.zoom ?? 0, value.rotation ?? 0, value.viewport_x ?? 0, value.viewport_y ?? 0, value.viewport_w ?? 0, value.viewport_h ?? 0);
        break;
      }
      default: fail(`operation ${operation.op}`);
    }
  }
  call(runtime, host, commands, "up_browser_present", 0);
  return {commands, dimensions: {width: fixture.width, height: fixture.height}};
}

function composite(source, destination, blend) {
  const alpha = source.a;
  if (blend === 0) return {r: Math.floor((source.r * alpha + destination.r * (255 - alpha)) / 255), g: Math.floor((source.g * alpha + destination.g * (255 - alpha)) / 255), b: Math.floor((source.b * alpha + destination.b * (255 - alpha)) / 255), a: 255};
  return {r: Math.min(255, destination.r + Math.floor(source.r * alpha / 255)), g: Math.min(255, destination.g + Math.floor(source.g * alpha / 255)), b: Math.min(255, destination.b + Math.floor(source.b * alpha / 255)), a: 255};
}

function transformRect(operation, transform) {
  if (!transform) return {x: operation.x, y: operation.y, w: operation.w, h: operation.h};
  const x = transform.viewport_x + transform.viewport_w / 2 + (operation.x - transform.x) * transform.zoom;
  const y = transform.viewport_y + transform.viewport_h / 2 + (operation.y - transform.y) * transform.zoom;
  const w = operation.w * transform.zoom;
  const h = operation.h * transform.zoom;
  if (![x, y, w, h].every(Number.isInteger)) fail("nonintegral reference transform");
  return {x, y, w, h};
}

export function referenceRendererContract(fixture) {
  validateRendererContract(fixture);
  const assets = assetMap(fixture);
  const pixels = new Uint8Array(fixture.width * fixture.height * 4);
  let clip = null;
  const clips = [];
  let blend = 0;
  const blends = [];
  let transform = null;
  const setPixel = (x, y, value) => {
    if (x < 0 || y < 0 || x >= fixture.width || y >= fixture.height || (clip && (x < clip.x || y < clip.y || x >= clip.x + clip.w || y >= clip.y + clip.h))) return;
    const offset = (y * fixture.width + x) * 4;
    const result = composite(value, {r: pixels[offset], g: pixels[offset + 1], b: pixels[offset + 2], a: pixels[offset + 3]}, blend);
    pixels[offset] = result.r; pixels[offset + 1] = result.g; pixels[offset + 2] = result.b; pixels[offset + 3] = result.a;
  };
  for (const operation of fixture.operations) {
    switch (operation.op) {
      case "clear":
        for (let offset = 0; offset < pixels.length; offset += 4) {
          pixels[offset] = operation.color.r; pixels[offset + 1] = operation.color.g; pixels[offset + 2] = operation.color.b; pixels[offset + 3] = operation.color.a;
        }
        break;
      case "rect": {
        const rect = transformRect(operation, transform);
        const bounded = clip ? intersect(rect, clip) : rect;
        for (let y = bounded.y; y < bounded.y + bounded.h; y += 1) for (let x = bounded.x; x < bounded.x + bounded.w; x += 1) setPixel(x, y, operation.color);
        break;
      }
      case "image": {
        const asset = assets.get(operation.asset);
        if (!asset) fail("image asset");
        for (let y = 0; y < asset.height; y += 1) for (let x = 0; x < asset.width; x += 1) {
          const offset = (y * asset.width + x) * 4;
          setPixel(operation.x + x, operation.y + y, {r: asset.rgba[offset], g: asset.rgba[offset + 1], b: asset.rgba[offset + 2], a: asset.rgba[offset + 3]});
        }
        break;
      }
      case "text": {
        const glyph = [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001];
        if (operation.value !== "A") fail("text glyph");
        for (let y = 0; y < glyph.length; y += 1) for (let x = 0; x < 5; x += 1) if ((glyph[y] & (1 << (4 - x))) !== 0) setPixel(operation.x + x, operation.y + y, operation.color);
        break;
      }
      case "push_clip": clips.push(clip); clip = clip ? intersect(clip, operation) : {x: operation.x, y: operation.y, w: operation.w, h: operation.h}; break;
      case "pop_clip": clip = clips.pop(); break;
      case "push_blend": blends.push(blend); blend = operation.mode; break;
      case "pop_blend": blend = blends.pop(); break;
      case "set_camera": transform = operation.camera.enabled ? operation.camera : null; break;
      default: fail(`operation ${operation.op}`);
    }
  }
  return {dimensions: {width: fixture.width, height: fixture.height}, pixels: Array.from(pixels)};
}

export function compareRendererContractCapture(fixture, capture) {
  const expected = referenceRendererContract(fixture);
  if (capture?.dimensions?.width !== expected.dimensions.width || capture.dimensions.height !== expected.dimensions.height || !Array.isArray(capture.pixels) || capture.pixels.length !== expected.pixels.length) return {expected, max_delta: null, mismatches: [{reason: "capture_dimensions_mismatch"}]};
  const mismatches = [];
  let maxDelta = 0;
  for (let index = 0; index < expected.pixels.length; index += 1) {
    const delta = Math.abs(expected.pixels[index] - capture.pixels[index]);
    maxDelta = Math.max(maxDelta, delta);
    if (delta <= rendererContractTolerance || mismatches.length === 64) continue;
    const pixel = Math.floor(index / 4);
    mismatches.push({x: pixel % expected.dimensions.width, y: Math.floor(pixel / expected.dimensions.width), channel: index % 4, expected: expected.pixels[index], actual: capture.pixels[index], delta});
  }
  return {expected, max_delta: maxDelta, mismatches};
}
