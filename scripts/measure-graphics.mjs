import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { Buffer } from 'node:buffer';
import { performance } from 'node:perf_hooks';
import process from 'node:process';
import { fileURLToPath, URL } from 'node:url';
import { gunzipSync } from 'node:zlib';
import { build } from 'vite';

// compare trusted repository implementations against immutable browser commands, without fixture writes.
const root = fileURLToPath(new URL('../', import.meta.url));
const graphicsPath = `${root}packages/runtime/src/graphics.ts`;
const baseline = execFileSync('git', ['show', '2bd8c4d:packages/runtime/src/graphics.ts'], {
  cwd: root,
  encoding: 'utf8',
});
const fixtures = new URL('../tests/fixtures/alpha/', import.meta.url);
const read = (name) => readFileSync(new URL(name, fixtures));
const projects = new Map(
  JSON.parse(gunzipSync(read('indexeddb.json.gz')), (_key, value) =>
    value?.alphaUint8Array === undefined ? value : Uint8Array.from(value.alphaUint8Array),
  ),
);
const catalogs = JSON.parse(read('catalogs.json'));

async function implementation(previous) {
  const result = await build({
    configFile: false,
    logLevel: 'silent',
    plugins: [
      {
        name: 'graphics-measurement',
        enforce: 'pre',
        resolveId(id) {
          if (id === `${root}measurement`) return '\0measurement';
        },
        load(id) {
          if (id === '\0measurement')
            return `export {IndexedGraphics,VisualAssetStore} from ${JSON.stringify(graphicsPath)}; export {decodeRuntimeAssets} from ${JSON.stringify(`${root}packages/runtime/src/asset-codec.ts`)};`;
          if (previous && id === graphicsPath) return baseline;
        },
      },
    ],
    build: { write: false, minify: false, lib: { entry: `${root}measurement`, formats: ['es'] } },
  });
  const output = (Array.isArray(result) ? result[0] : result).output;
  const chunk = output.find((entry) => entry.type === 'chunk' && entry.isEntry);
  if (chunk === undefined) throw new Error('missing measurement bundle');
  return import(`data:text/javascript;base64,${Buffer.from(chunk.code).toString('base64')}`);
}

const previous = await implementation(true);
const current = await implementation(false);
const results = {};
for (const id of ['cinder-circuit', 'ashvault', 'raster-rush']) {
  const trace = JSON.parse(gunzipSync(read(`${id}.trace.json.gz`)));
  results[id] = {};
  const renderers = [];
  for (const [label, core] of [
    ['previous', previous],
    ['current', current],
  ]) {
    const catalog = catalogs[id];
    const assets = core.decodeRuntimeAssets(
      catalog.assets,
      projects.get(`project/${id}`).files,
      catalog.display,
    );
    const graphics = new core.IndexedGraphics(
      new core.VisualAssetStore(assets.visual),
      assets.display,
    );
    for (const frame of trace.frames) {
      const hash = createHash('sha256')
        .update(graphics.executeFrame(frame.drawCommands).indexedPixels)
        .digest('hex');
      if (hash !== frame.framebufferHash)
        throw new Error(`${label} ${id} frame ${frame.frame}: output differs`);
    }
    renderers.push([label, graphics]);
    results[id][label] = [];
  }
  for (let round = 0; round < 5; round += 1) {
    // alternate execution order to reduce host-load and warmup bias.
    for (const [label, graphics] of round % 2 === 0 ? renderers : renderers.toReversed()) {
      const cpu = process.cpuUsage();
      const wall = performance.now();
      for (const frame of trace.frames) graphics.executeFrame(frame.drawCommands);
      const elapsed = process.cpuUsage(cpu);
      results[id][label].push({
        cpuMs: (elapsed.user + elapsed.system) / 1000,
        wallMs: performance.now() - wall,
      });
    }
  }
}
process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
