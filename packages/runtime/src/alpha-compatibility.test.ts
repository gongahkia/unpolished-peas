import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';

import { decodeRuntimeAssets, type ProjectAssetDeclaration } from './asset-codec';
import { AudioAssetStore, Synthesizer } from './audio';
import { IndexedGraphics, VisualAssetStore } from './graphics';
import type { StoredProject } from './persistence';
import type { ConsoleCommand } from './protocol';

const directory = new URL('../../../tests/fixtures/alpha/', import.meta.url);
const read = (name: string): Buffer => readFileSync(new URL(name, directory));
const hash = (bytes: Uint8Array | string): string =>
  createHash('sha256').update(bytes).digest('hex');
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
        const pcm = new Uint8Array(audio.left.length * 8);
        const view = new DataView(pcm.buffer);
        for (let sample = 0; sample < audio.left.length; sample += 1) {
          view.setFloat32(sample * 8, audio.left[sample] ?? 0, true);
          view.setFloat32(sample * 8 + 4, audio.right[sample] ?? 0, true);
        }
        pcmHash.update(pcm);
      }
      expect({
        visualBytes: assets.visualBytes,
        peakVoices,
        pcmHash: pcmHash.digest('hex'),
      }).toEqual(audioMetrics[id]);
    });
  }
});
