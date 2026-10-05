import {readFile} from "node:fs/promises";

const wasmPath = process.argv[2];
if (!wasmPath) throw new Error("expected authored-assets Wasm path");

const memory = new WebAssembly.Memory({initial: 32});
const bytes = await readFile(wasmPath);
const {instance} = await WebAssembly.instantiate(bytes, {env: {memory}});
const runtime = instance.exports;

const imageWidth = runtime.up_authored_image_width();
const imageHash = runtime.up_authored_image_hash();
const fontGlyphCount = runtime.up_authored_font_glyph_count();
const fontCanvasHash = runtime.up_authored_font_canvas_hash();
if (imageWidth !== 16) throw new Error("embedded PNG width mismatch");
if (imageHash !== -8_082_875_053_824_912_137n) throw new Error("embedded PNG pixels changed");
if (fontGlyphCount !== 96) throw new Error("embedded TrueType glyph set changed");
if (fontCanvasHash !== 6_940_701_260_184_702_440n) throw new Error("embedded TrueType rasterization changed");

console.log("browser authored image and font asset smoke passed");
