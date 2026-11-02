export const stableImageAssetDiagnostic = "asset_load_failed:image_v1";
export const stableImageLimits = Object.freeze({maxInputBytes: 32 * 1024 * 1024, maxWidth: 4096, maxHeight: 4096, maxPixels: 4096 * 4096});

export class StableImageAssetError extends Error {
  constructor() {
    super(stableImageAssetDiagnostic);
    this.code = stableImageAssetDiagnostic;
  }
}

function fail() {
  throw new StableImageAssetError();
}

function validDimensions(width, height) {
  return Number.isInteger(width) && Number.isInteger(height) && width > 0 && height > 0 && width <= stableImageLimits.maxWidth && height <= stableImageLimits.maxHeight && width * height <= stableImageLimits.maxPixels;
}

function u16(bytes, offset) {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

function u32be(bytes, offset) {
  return ((bytes[offset] * 0x1000000) + (bytes[offset + 1] << 16) + (bytes[offset + 2] << 8) + bytes[offset + 3]) >>> 0;
}

function png(bytes) {
  if (bytes.length < 24 || ![137, 80, 78, 71, 13, 10, 26, 10].every((value, index) => bytes[index] === value)) return null;
  const width = u32be(bytes, 16);
  const height = u32be(bytes, 20);
  if (!validDimensions(width, height)) fail();
  return {format: "png", mime: "image/png", width, height};
}

function jpeg(bytes) {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  let offset = 2;
  while (offset < bytes.length) {
    while (offset < bytes.length && bytes[offset] === 0xff) offset += 1;
    if (offset >= bytes.length) fail();
    const marker = bytes[offset];
    offset += 1;
    if (marker === 0xd9 || marker === 0xda) break;
    if (marker >= 0xd0 && marker <= 0xd7) continue;
    if (offset + 2 > bytes.length) fail();
    const length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) fail();
    if ((marker >= 0xc0 && marker <= 0xc3) || (marker >= 0xc5 && marker <= 0xc7) || (marker >= 0xc9 && marker <= 0xcb) || (marker >= 0xcd && marker <= 0xcf)) {
      if (length < 8) fail();
      const height = (bytes[offset + 3] << 8) | bytes[offset + 4];
      const width = (bytes[offset + 5] << 8) | bytes[offset + 6];
      if (!validDimensions(width, height)) fail();
      return {format: "jpeg", mime: "image/jpeg", width, height};
    }
    offset += length;
  }
  fail();
}

function tga(bytes) {
  if (bytes.length < 18 || bytes[1] !== 0 || bytes[2] !== 2 || (bytes[16] !== 24 && bytes[16] !== 32)) return null;
  const width = u16(bytes, 12);
  const height = u16(bytes, 14);
  const bytesPerPixel = bytes[16] / 8;
  const offset = 18 + bytes[0];
  if (!validDimensions(width, height) || offset > bytes.length || width * height > Math.floor((bytes.length - offset) / bytesPerPixel)) fail();
  return {format: "tga", mime: null, width, height, offset, bytesPerPixel, topOrigin: (bytes[17] & 0x20) !== 0};
}

export function inspectStableImage(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length === 0 || bytes.length > stableImageLimits.maxInputBytes) fail();
  return png(bytes) ?? jpeg(bytes) ?? tga(bytes) ?? fail();
}

function decodeTga(bytes, info) {
  const pixels = new Uint8Array(info.width * info.height * 4);
  for (let sourceY = 0; sourceY < info.height; sourceY += 1) for (let x = 0; x < info.width; x += 1) {
    const source = info.offset + (sourceY * info.width + x) * info.bytesPerPixel;
    const destinationY = info.topOrigin ? sourceY : info.height - 1 - sourceY;
    const destination = (destinationY * info.width + x) * 4;
    pixels[destination] = bytes[source + 2]; pixels[destination + 1] = bytes[source + 1]; pixels[destination + 2] = bytes[source]; pixels[destination + 3] = info.bytesPerPixel === 4 ? bytes[source + 3] : 255;
  }
  return {...info, pixels};
}

function pixelsFromBitmap(bitmap, width, height, {OffscreenCanvas: OffscreenCanvasImpl = globalThis.OffscreenCanvas, document: documentRef = globalThis.document} = {}) {
  const canvas = OffscreenCanvasImpl ? new OffscreenCanvasImpl(width, height) : documentRef?.createElement?.("canvas");
  if (!canvas) fail();
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d", {willReadFrequently: true});
  if (!context) fail();
  context.drawImage(bitmap, 0, 0);
  return new Uint8Array(context.getImageData(0, 0, width, height).data);
}

export async function decodeStableImage(bytes, options = {}) {
  const info = inspectStableImage(bytes);
  if (info.format === "tga") return decodeTga(bytes, info);
  const createImageBitmapImpl = options.createImageBitmap ?? globalThis.createImageBitmap;
  const BlobImpl = options.Blob ?? globalThis.Blob;
  if (typeof createImageBitmapImpl !== "function" || typeof BlobImpl !== "function") fail();
  let bitmap;
  try {
    bitmap = await createImageBitmapImpl(new BlobImpl([bytes], {type: info.mime}), {colorSpaceConversion: "none", premultiplyAlpha: "none"});
    if (bitmap.width !== info.width || bitmap.height !== info.height) fail();
    return {...info, pixels: pixelsFromBitmap(bitmap, info.width, info.height, options)};
  } catch (error) {
    if (error instanceof StableImageAssetError) throw error;
    fail();
  } finally {
    bitmap?.close?.();
  }
}
