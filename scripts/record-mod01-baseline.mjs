/* global console, process, window, Worker, WebGL2RenderingContext, indexedDB, performance, TextEncoder, TextDecoder */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';
import { firefox } from '@playwright/test';

// Records the clean-break MOD-01 baseline from a local production preview.
const baseURL = process.env.MOD01_BASELINE_URL ?? 'http://127.0.0.1:4173';
const latencyOnly = process.argv.includes('--latency-only');
const directory = 'tests/fixtures/mod01-baseline';
await mkdir(directory, { recursive: true });
await mkdir('output/playwright', { recursive: true });
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const browser = await firefox.launch();
const metrics = { baseline: 'MOD-01 clean break', browser: `Firefox ${browser.version()}`, cartridges: {} };
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await context.newPage();
  page.setDefaultTimeout(30000);
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.addInitScript(() => {
    window.mod01BaselineCapture = { frames: [], pixels: [], snapshots: [], limit: 240, id: '' };
    const capture = window.mod01BaselineCapture;
    const animationFrame = window.requestAnimationFrame.bind(window);
    window.requestAnimationFrame = (callback) => {
      const cartridgeLoop = new Error().stack.includes('/assets/index-');
      return animationFrame((timestamp) => {
        if (!cartridgeLoop || capture.frames.length < capture.limit) callback(timestamp);
      });
    };
    const post = Worker.prototype.postMessage;
    Worker.prototype.postMessage = function (message, ...rest) {
      if (message.type === 'load') {
        capture.configuration = message.configuration;
        this.addEventListener('message', (event) => {
          if (event.data.type === 'frame') {
            const { frame, workUnits, drawCommands, audioCommands, saveWrites } = event.data;
            capture.frames.push({ frame, workUnits, drawCommands, audioCommands, saveWrites });
            post.call(this, { id: 900000 + frame, type: 'snapshot' });
          } else if (event.data.type === 'snapshot') {
            capture.snapshots.push(event.data.snapshot);
          } else if (event.data.type === 'error') {
            capture.error = event.data;
          }
        });
      } else if (message.type === 'frame') {
        const frame = capture.frames.length;
        const buttons = [
          'up',
          'down',
          'left',
          'right',
          'a',
          'b',
          'x',
          'y',
          'l',
          'r',
          'start',
          'menu',
        ];
        const controllers = Array.from({ length: 4 }, () => ({
          buttons: Object.fromEntries(buttons.map((button) => [button, false])),
        }));
        if (capture.id === 'cinder-circuit') {
          controllers[0].buttons.a = frame === 2 || frame === 60 || frame === 110 || frame === 170;
          controllers[0].buttons.right = frame >= 10 && frame < 230;
        } else if (capture.id === 'ashvault') {
          controllers[0].buttons.a = frame === 2;
          if (frame >= 20 && frame % 20 === 0)
            controllers[0].buttons[['right', 'down', 'left', 'up'][Math.floor(frame / 60) % 4]] =
              true;
        } else {
          controllers[0].buttons.start = frame === 2;
          for (let port = 0; port < 4; port += 1) {
            controllers[port].buttons.a = frame >= 4;
            controllers[port].buttons.x = frame === 60 + port * 10;
            controllers[port].buttons[port % 2 === 0 ? 'left' : 'right'] =
              frame >= 100 && frame < 120;
          }
        }
        message.input = {
          controllers,
          pointer: { x: 0, y: 0, primary: false, secondary: false, inside: false },
        };
        capture.inputs ??= [];
        capture.inputs.push(message.input);
      }
      return post.call(this, message, ...rest);
    };
    const texture = WebGL2RenderingContext.prototype.texSubImage2D;
    WebGL2RenderingContext.prototype.texSubImage2D = function (...args) {
      if (args[4] === 240 && args[5] === 144) capture.pixels.push(Array.from(args[8]));
      return texture.apply(this, args);
    };
  });
  const command = async (text) => {
    const input = page.getByLabel('MOD-01 command');
    await input.fill(text);
    await input.press('Enter');
  };
  await page.goto(baseURL);
  await page.waitForSelector('html[data-studio-ready="true"]');
  await page.screenshot({ path: 'output/playwright/mod01-baseline-shell.png' });
  for (const id of latencyOnly ? [] : ['cinder-circuit', 'ashvault', 'raster-rush']) {
    console.log(`recording ${id}`);
    await command(`load ${id}`);
    await page.locator('.active-cart').filter({ hasText: id.toUpperCase() }).waitFor();
    await page.evaluate(
      (id) =>
        Object.assign(window.mod01BaselineCapture, {
          id,
          frames: [],
          pixels: [],
          snapshots: [],
          inputs: [],
        }),
      id,
    );
    await command('run');
    await page.waitForFunction(
      () => window.mod01BaselineCapture.snapshots.length >= 240 || window.mod01BaselineCapture.error,
      undefined,
      { polling: 20 },
    );
    const capture = JSON.parse(await page.evaluate(() => JSON.stringify(window.mod01BaselineCapture)));
    console.log({
      frames: capture.frames.length,
      pixels: capture.pixels.length,
      snapshots: capture.snapshots.length,
      first: capture.frames.slice(0, 3).map((frame) => frame.frame),
      last: capture.frames.slice(-3).map((frame) => frame.frame),
    });
    assert.equal(capture.error, undefined);
    assert.equal(capture.frames.length, 240);
    assert.equal(capture.pixels.length, 240);
    const frames = capture.frames.map((frame, index) => ({
      ...frame,
      input: capture.inputs[index],
      framebufferHash: hash(Uint8Array.from(capture.pixels[index])),
      stateHash: hash(JSON.stringify(capture.snapshots[index])),
    }));
    const trace = {
      revision: 1,
      baseline: 'MOD-01 clean break',
      id,
      configuration: capture.configuration,
      frames,
      finalSnapshot: capture.snapshots.at(-1),
    };
    const bytes = await readFile(`apps/studio/public/cartridges/${id}.m01c`);
    await writeFile(`${directory}/${id}.m01c`, bytes, { flag: 'w' });
    await writeFile(
      `${directory}/${id}.trace.json.gz`,
      gzipSync(JSON.stringify(trace), { level: 9 }),
      { flag: 'w' },
    );
    metrics.cartridges[id] = {
      bytes: bytes.length,
      sha256: hash(bytes),
      peakWork: Math.max(...frames.map((frame) => frame.workUnits)),
      peakDrawCommands: Math.max(...frames.map((frame) => frame.drawCommands.length)),
      peakAudioCommands: Math.max(...frames.map((frame) => frame.audioCommands.length)),
      finalFramebufferHash: frames.at(-1).framebufferHash,
      finalStateHash: frames.at(-1).stateHash,
      audioCommandHash: hash(JSON.stringify(frames.map((frame) => frame.audioCommands))),
    };
    await page.locator('.player-screen').screenshot({ path: `output/playwright/mod01-baseline-.png` });
    await page.locator('.stop-player').click();
  }
  const records = await page.evaluate(
    () =>
      new Promise((resolve, reject) => {
        const request = indexedDB.open('mod01-studio');
        request.onerror = () => reject(request.error);
        request.onsuccess = () => {
          const database = request.result;
          const store = database.transaction('records').objectStore('records');
          const values = store.getAll();
          const keys = store.getAllKeys();
          keys.onsuccess = () => {
            resolve(keys.result.map((key, index) => [key, values.result[index]]));
            database.close();
          };
        };
      }),
  );
  if (!latencyOnly)
    await writeFile(
      `${directory}/indexeddb.json.gz`,
      gzipSync(
        JSON.stringify(records, (_key, value) =>
          value instanceof Uint8Array ? { mod01BaselineUint8Array: [...value] } : value,
        ),
        { level: 9 },
      ),
      { flag: 'w' },
    );

  if (latencyOnly) {
    await page.evaluate(
      () =>
        new Promise((resolve, reject) => {
          const request = indexedDB.open('mod01-studio');
          request.onerror = () => reject(request.error);
          request.onsuccess = () => {
            const database = request.result;
            const transaction = database.transaction('records', 'readwrite');
            const store = transaction.objectStore('records');
            const read = store.get('project/cinder-circuit');
            read.onsuccess = () => {
              const project = read.result;
              const source = new TextDecoder().decode(project.files['src/main.modl']);
              const split = source.indexOf('\non start:');
              if (split < 0) {
                transaction.abort();
                reject(new Error('missing benchmark split'));
                return;
              }
              project.files['src/logic.modl'] = new TextEncoder().encode(source.slice(0, split));
              project.files['src/main.modl'] = new TextEncoder().encode(
                `import src.logic as logic\n${source.slice(split)}`,
              );
              store.put(project, 'project/cinder-circuit');
            };
            transaction.oncomplete = () => {
              database.close();
              resolve();
            };
            transaction.onerror = () => reject(transaction.error);
          };
        }),
    );
  }

  // includes filling an actual source edit, saving/back, compilation, Worker boot and first render.
  await command('load cinder-circuit');
  await page.locator('.active-cart').filter({ hasText: 'CINDER-CIRCUIT' }).waitFor();
  const latencies = [];
  for (let index = 0; index < 11; index += 1) {
    await command('edit');
    const source = page.locator('textarea.source-input');
    const original = await source.inputValue();
    await page.evaluate(() =>
      Object.assign(window.mod01BaselineCapture, {
        frames: [],
        pixels: [],
        snapshots: [],
        inputs: [],
        limit: 1,
      }),
    );
    const start = performance.now();
    await source.fill(`${original}\n// latency sample ${index}\n`);
    await page.locator('[data-action="back"]').click();
    await command('run');
    await page.waitForFunction(() => window.mod01BaselineCapture.pixels.length === 1, undefined, {
      polling: 5,
    });
    latencies.push(performance.now() - start);
    await page.locator('.stop-player').click();
  }
  metrics.editRun = {
    description: `Playwright wall clock, fill edit + save/back + run + first rendered frame; one cold, ten warm; Cinder Circuit ${latencyOnly ? 'split into two modules in an isolated browser profile' : 'original single-file project'}`,
    coldMilliseconds: latencies[0],
    warmMilliseconds: latencies.slice(1),
    medianMilliseconds:
      latencies
        .slice(1)
        .sort((a, b) => a - b)
        .slice(4, 6)
        .reduce((a, b) => a + b) / 2,
  };
  assert.deepEqual(errors, []);
  await writeFile(
    `${directory}/${latencyOnly ? 'latency' : 'metrics'}.json`,
    `${JSON.stringify(metrics, null, 2)}\n`,
    { flag: 'w' },
  );
  console.log(JSON.stringify(metrics, null, 2));
} finally {
  await browser.close();
}
