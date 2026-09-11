import { createHash } from 'node:crypto';
import { deepStrictEqual } from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { gunzipSync } from 'node:zlib';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import { decodeRuntimeAssets, type ProjectAssetDeclaration } from './asset-codec';
import { AudioAssetStore, Synthesizer, type AudioFrame } from './audio';
import { createConsoleRuntime, type ConsoleRuntimeSnapshot } from './console-runtime';
import { IndexedGraphics, VisualAssetStore } from './graphics';
import type { InputFrame } from './input';
import type { CartridgeFactory } from './machine';
import { MemoryStorage, StudioRepository, type StoredProject } from './persistence';
import type { ConsoleCommand, SandboxConfiguration } from './protocol';
import { SaveMemory } from './save';

const directory = new URL('../../../tests/fixtures/alpha/', import.meta.url);
const read = (name: string): Buffer => readFileSync(new URL(name, directory));
const hash = (bytes: Uint8Array | string): string =>
  createHash('sha256').update(bytes).digest('hex');
const legacySnapshot = (snapshot: ConsoleRuntimeSnapshot): unknown => ({
  revision: 1,
  machine: {
    revision: 1,
    frame: snapshot.machine.frame,
    rngState: snapshot.machine.rngState,
    cartridge: snapshot.machine.cartridge,
    input: snapshot.machine.input,
    previousInput: snapshot.machine.previousInput,
  },
  save: new SaveMemory(snapshot.save.bytes).snapshot(),
});
function pcmBytes(audio: AudioFrame): Uint8Array {
  const pcm = new Uint8Array(audio.left.length * 8);
  const view = new DataView(pcm.buffer);
  for (let sample = 0; sample < audio.left.length; sample += 1) {
    view.setFloat32(sample * 8, audio.left[sample] ?? 0, true);
    view.setFloat32(sample * 8 + 4, audio.right[sample] ?? 0, true);
  }
  return pcm;
}
const projects = new Map(
  JSON.parse(
    gunzipSync(read('indexeddb.json.gz')).toString(),
    (_key: string, value: unknown): unknown => {
      if (
        typeof value === 'object' &&
        value !== null &&
        'alphaUint8Array' in value &&
        Array.isArray(value.alphaUint8Array)
      ) {
        return Uint8Array.from(value.alphaUint8Array as number[]);
      }
      return value;
    },
  ) as [string, StoredProject][],
);
const catalogs = JSON.parse(read('catalogs.json').toString()) as Record<
  string,
  {
    assets: Record<string, ProjectAssetDeclaration>;
    display: string;
  }
>;
const metrics = JSON.parse(read('metrics.json').toString()) as {
  cartridges: Record<string, { bytes: number; sha256: string; audioCommandHash: string }>;
};
const audioMetrics = JSON.parse(read('audio.json').toString()) as Record<
  string,
  {
    visualBytes: number;
    peakVoices: number;
    pcmHash: string;
  }
>;

describe('immutable alpha recordings', () => {
  it('migrates the preserved raw alpha project and save while retaining backups', async () => {
    const legacy = projects.get('project/ashvault');
    if (legacy === undefined) throw new Error('missing alpha project fixture');
    const storage = new MemoryStorage();
    await storage.set('project/ashvault', legacy);
    await storage.set('save/ashvault', new Uint8Array(read('save.json')));
    const repository = new StudioRepository(storage);
    expect(await repository.loadProject('ashvault')).toMatchObject({
      id: 'ashvault',
      revision: 1,
      storageRevision: 1,
    });
    expect(await storage.get('migration/project/ashvault/alpha')).toEqual(legacy);
    const save = repository.cartridgeSave('ashvault');
    expect(new TextDecoder().decode(await save.read())).toContain('deepest_vault');
    expect(await save.schemaVersion()).toBe(0);
    expect(await storage.get('migration/save/ashvault/alpha')).toEqual(
      new Uint8Array(read('save.json')),
    );
  });

  for (const id of ['cinder-circuit', 'ashvault', 'raster-rush']) {
    it(`renders every ${id} browser frame through the production graphics and audio core`, () => {
      const project = projects.get(`project/${id}`);
      const catalog = catalogs[id];
      const metric = metrics.cartridges[id];
      expect(project).toBeDefined();
      expect(catalog).toBeDefined();
      expect(metric).toBeDefined();
      if (project === undefined || catalog === undefined || metric === undefined)
        throw new Error('missing alpha fixture');
      const packed = read(`${id}.pxc`);
      expect(packed.length).toBe(metric.bytes);
      expect(hash(packed)).toBe(metric.sha256);
      const trace = JSON.parse(gunzipSync(read(`${id}.trace.json.gz`)).toString()) as {
        frames: {
          frame: number;
          framebufferHash: string;
          drawCommands: ConsoleCommand[];
          audioCommands: ConsoleCommand[];
        }[];
      };
      expect(trace.frames).toHaveLength(240);
      expect(hash(JSON.stringify(trace.frames.map((frame) => frame.audioCommands)))).toBe(
        metric.audioCommandHash,
      );
      const assets = decodeRuntimeAssets(catalog.assets, project.files, catalog.display);
      const graphics = new IndexedGraphics(new VisualAssetStore(assets.visual), assets.display);
      const synth = new Synthesizer(new AudioAssetStore(assets.audio));
      const pcmHash = createHash('sha256');
      let peakVoices = 0;
      for (const frame of trace.frames) {
        expect(
          hash(graphics.executeFrame(frame.drawCommands).indexedPixels),
          `frame ${String(frame.frame)}`,
        ).toBe(frame.framebufferHash);
        const audio = synth.executeFrame(frame.audioCommands);
        peakVoices = Math.max(peakVoices, audio.activeVoices);
        pcmHash.update(pcmBytes(audio));
      }
      expect({
        visualBytes: assets.visualBytes,
        peakVoices,
        pcmHash: pcmHash.digest('hex'),
      }).toEqual(audioMetrics[id]);
    });
  }
});

describe('shared Worker core versus alpha browser execution', () => {
  const root = fileURLToPath(new URL('../../../', import.meta.url));
  let temporary: string;
  beforeAll(() => {
    temporary = mkdtempSync(join(tmpdir(), 'px240c-alpha-core-'));
    execFileSync('cargo', ['build', '--quiet', '--package', 'px240c-cli'], { cwd: root });
  }, 120_000);
  afterAll(() => {
    if (temporary) rmSync(temporary, { recursive: true, force: true });
  });
  for (const id of ['cinder-circuit', 'ashvault', 'raster-rush']) {
    it(`recompiles and executes ${id} with identical work, commands, saves and state`, async () => {
      const generatedPath = join(temporary, `${id}.mjs`);
      execFileSync(join(root, 'target/debug/px240c'), [
        'build',
        join(root, 'cartridges', id),
        '--output',
        generatedPath,
      ]);
      // only the authoritative compiler's fresh output is loaded, never embedded cartridge JS.
      const generated = (await import(/* @vite-ignore */ pathToFileURL(generatedPath).href)) as {
        default: CartridgeFactory;
      };
      const trace = JSON.parse(gunzipSync(read(`${id}.trace.json.gz`)).toString()) as {
        configuration: SandboxConfiguration;
        frames: {
          frame: number;
          input: InputFrame;
          workUnits: number;
          drawCommands: ConsoleCommand[];
          audioCommands: ConsoleCommand[];
          saveWrites: unknown;
          stateHash: string;
          framebufferHash: string;
        }[];
        finalSnapshot: unknown;
      };
      const project = projects.get(`project/${id}`);
      const catalog = catalogs[id];
      if (project === undefined || catalog === undefined) throw new Error('missing alpha assets');
      const assets = decodeRuntimeAssets(catalog.assets, project.files, catalog.display);
      const runtime = createConsoleRuntime(generated.default, {
        ...trace.configuration,
        maps: assets.maps,
        assets: {
          declarations: catalog.assets,
          files: project.files,
          displayPath: catalog.display,
        },
      });
      const original = runtime.snapshot();
      const snapshots: unknown[] = [];
      const pcmHash = createHash('sha256');
      let peakVoices = 0;
      for (const expected of trace.frames) {
        const actual = runtime.runFrame(expected.input);
        expect(actual.frame).toBe(expected.frame);
        expect(actual.workUnits).toBe(expected.workUnits);
        expect(actual.drawCommands).toEqual(expected.drawCommands);
        expect(actual.audioCommands).toEqual(expected.audioCommands);
        expect(actual.saveWrites).toEqual(expected.saveWrites);
        expect(hash(actual.output.indexedPixels)).toBe(expected.framebufferHash);
        pcmHash.update(pcmBytes(actual.output.audio));
        peakVoices = Math.max(peakVoices, actual.output.audio.activeVoices);
        expect(
          hash(JSON.stringify(legacySnapshot(runtime.snapshot()))),
          `frame ${String(expected.frame)}`,
        ).toBe(expected.stateHash);
        if (expected.frame < 10) snapshots.push(runtime.snapshot());
      }
      expect(legacySnapshot(runtime.snapshot())).toEqual(trace.finalSnapshot);
      expect({
        pcmHash: pcmHash.digest('hex'),
        peakVoices,
        visualBytes: assets.visualBytes,
      }).toEqual(audioMetrics[id]);
      runtime.restore(original);
      deepStrictEqual(runtime.snapshot(), original);
      for (const expected of trace.frames.slice(0, 10)) {
        runtime.runFrame(expected.input);
        deepStrictEqual(runtime.snapshot(), snapshots[expected.frame]);
        expect(hash(JSON.stringify(legacySnapshot(runtime.snapshot())))).toBe(expected.stateHash);
      }
    }, 30_000);
  }
});
