import {ResourceKind, Status} from "./host.mjs";
import {decodeStableImage} from "./image_asset.mjs";

const jpegBase64 = "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAaADAAQAAAABAAAAAQAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAAQABAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A/Xiiiiv5LP2A/9k=";
const tga = new Uint8Array([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 24, 0x20, 0, 0, 255, 0, 255, 0]);

function requireStatus(status, operation) {
  if (status !== Status.ok) throw new Error(`stable image asset command failed: ${operation}`);
}

function decodeBase64(value) {
  return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
}

function opaquePixel(image) {
  for (let offset = 0; offset < image.pixels.length; offset += 4) if (image.pixels[offset + 3] === 255) return {x: (offset / 4) % image.width, y: Math.floor(offset / 4 / image.width), color: image.pixels.slice(offset, offset + 4)};
  throw new Error("stable image asset has no opaque pixel");
}

async function capturePixel(host) {
  const image = new Image();
  image.src = host.captureFrame();
  await image.decode();
  const canvas = document.createElement("canvas");
  canvas.width = 1;
  canvas.height = 1;
  const context = canvas.getContext("2d", {willReadFrequently: true});
  context.drawImage(image, 0, 0);
  return new Uint8Array(context.getImageData(0, 0, 1, 1).data);
}

async function renderAsset(runtime, host, image) {
  const source = opaquePixel(image);
  const offset = 65536;
  if (offset > host.memory.buffer.byteLength - image.pixels.length) throw new Error("stable image asset exceeds Wasm memory");
  new Uint8Array(host.memory.buffer, offset, image.pixels.length).set(image.pixels);
  const texture = runtime.up_browser_gl_resource_create(ResourceKind.texture, 0);
  if (!texture) throw new Error("stable image texture unavailable");
  try {
    requireStatus(runtime.up_browser_gl_context_create(1, 1), "context_create");
    requireStatus(runtime.up_browser_clear(0), "clear");
    requireStatus(runtime.up_browser_texture_upload(texture, image.width, image.height, offset, image.pixels.length, 0), "texture_upload");
    requireStatus(runtime.up_browser_draw_sprite(texture, source.x, source.y, 1, 1, 0, 0, 1, 1, 0xffffffff, 0), "draw_sprite");
    requireStatus(runtime.up_browser_present(0), "present");
    const actual = await capturePixel(host);
    if (!actual.every((value, index) => value === source.color[index])) throw new Error("stable image asset capture mismatch");
  } finally {
    runtime.up_browser_gl_resource_destroy(ResourceKind.texture, texture);
  }
}

export async function verifyStableImageAssets(runtime, host, url) {
  const images = [await host.loadStableImageAsset(url), await decodeStableImage(decodeBase64(jpegBase64)), await decodeStableImage(tga)];
  for (const image of images) await renderAsset(runtime, host, image);
  return images.map((image) => ({format: image.format, width: image.width, height: image.height}));
}
