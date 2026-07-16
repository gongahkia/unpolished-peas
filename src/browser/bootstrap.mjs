import {createBrowserHost, Status} from "./host.mjs";

async function instantiate(url, imports) {
  try {
    return await WebAssembly.instantiateStreaming(fetch(url), imports);
  } catch {
    return WebAssembly.instantiate(await (await fetch(url)).arrayBuffer(), imports);
  }
}

const canvas = document.querySelector("canvas[data-unpolished-peas]");
if (!canvas) throw new Error("unpolished-peas browser: missing canvas");
const host = createBrowserHost({canvas});
const result = await instantiate("./unpolished-peas.wasm", host.imports);
const runtime = result.instance.exports;
if (!host.attachRuntime(runtime)) throw new Error("unpolished-peas browser: invalid Wasm runtime");
const width = Math.max(1, Math.floor(canvas.clientWidth || canvas.width || 320));
const height = Math.max(1, Math.floor(canvas.clientHeight || canvas.height || 180));
if (runtime.up_browser_gl_context_create(width, height) !== Status.ok) throw new Error("unpolished-peas browser: WebGL 2 unavailable");
if (runtime.up_browser_init(width, height) !== Status.ok) throw new Error("unpolished-peas browser: runtime initialization failed");
window.unpolishedPeas = {host, runtime};
