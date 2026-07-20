import assert from "node:assert/strict";
import {decodeStableImage, inspectStableImage, stableImageAssetDiagnostic, stableImageLimits} from "../src/browser/image_asset.mjs";

const png = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 1]);
const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xc0, 0, 8, 8, 0, 1, 0, 1, 3, 0, 0, 0, 0, 0xff, 0xd9]);
const tga = new Uint8Array([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 24, 0x20, 0, 0, 255, 0, 255, 0]);

assert.deepEqual(inspectStableImage(png), {format: "png", mime: "image/png", width: 2, height: 1});
assert.deepEqual(inspectStableImage(jpeg), {format: "jpeg", mime: "image/jpeg", width: 1, height: 1});
const decodedTga = await decodeStableImage(tga);
assert.equal(decodedTga.format, "tga");
assert.deepEqual([...decodedTga.pixels], [255, 0, 0, 255, 0, 255, 0, 255]);
assert.throws(() => inspectStableImage(new Uint8Array([66, 77, 0, 0])), new RegExp(stableImageAssetDiagnostic));
assert.throws(() => inspectStableImage(new Uint8Array([...png.slice(0, 16), 0, 0, 0x10, 1, 0, 0, 0, 1])), new RegExp(stableImageAssetDiagnostic));
assert.equal(stableImageLimits.maxInputBytes, 32 * 1024 * 1024);
