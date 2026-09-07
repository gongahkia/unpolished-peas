import { describe, expect, it } from 'vitest';

import {
  decodeRuntimeAssets,
  encodeAssetFile,
  encodeMusicAssetFile,
  encodeSoundAssetFile,
} from './asset-codec';
import type { SoundAsset } from './audio';
import { IndexedGraphics, VisualAssetStore } from './graphics';

const sound = {
  revision: 1,
  kind: 'sound',
  waveform: 'pulse',
  note: 60,
  durationFrames: 8,
  volume: 0.5,
  pan: 0,
  duty: 0.5,
  envelope: { attackFrames: 0, decayFrames: 1, sustainLevel: 0.8, releaseFrames: 2 },
  pitch: { slideSemitonesPerFrame: 0, vibratoDepthSemitones: 0, vibratoPeriodFrames: 0 },
};

describe('source-visible asset codec', () => {
  it('adds the file revision and removes runtime names when encoding audio assets', () => {
    const encodedSound: unknown = JSON.parse(
      new TextDecoder().decode(encodeSoundAssetFile({ ...sound, name: 'beep' } as SoundAsset)),
    );
    const encodedMusic: unknown = JSON.parse(
      new TextDecoder().decode(
        encodeMusicAssetFile({
          kind: 'music',
          name: 'theme',
          framesPerRow: 6,
          order: ['00'],
          patterns: { '00': { rows: [[null, null, null, null, null, null, null, null]] } },
          loop: true,
        }),
      ),
    );

    expect(encodedSound).toMatchObject({ revision: 1, kind: 'sound' });
    expect(encodedMusic).toMatchObject({ revision: 1, kind: 'music' });
    expect(encodedSound).not.toHaveProperty('name');
    expect(encodedMusic).not.toHaveProperty('name');
  });

  it('loads indexed graphics, map query views, synth patches, and tracker patterns', () => {
    const files = {
      'hero.pxg': encodeAssetFile({
        revision: 1,
        kind: 'sprite',
        width: 2,
        height: 2,
        frames: [[0, 7, 7, 0]],
      }),
      'tiles.pxg': encodeAssetFile({
        revision: 1,
        kind: 'tile_set',
        tiles: [Array.from({ length: 64 }, () => 3)],
        flags: [1],
      }),
      'room.pxm': encodeAssetFile({
        revision: 1,
        kind: 'map',
        layers: [{ width: 2, height: 1, cells: [0, 0], tileSet: 'tiles' }],
      }),
      'beep.pxs': encodeAssetFile(sound),
      'theme.pxt': encodeAssetFile({
        revision: 1,
        kind: 'music',
        framesPerRow: 4,
        order: ['a'],
        patterns: {
          a: {
            rows: [[{ note: 60, sound: 'beep' }, null, null, null, null, null, null, null]],
          },
        },
        loop: true,
      }),
      'display.pxp': encodeAssetFile({
        revision: 1,
        kind: 'display',
        remap: Array.from({ length: 32 }, (_, index) => (index === 1 ? 7 : index)),
        raster: [
          {
            line: 1,
            scrollX: 0,
            scrollY: 0,
            remap: Array.from({ length: 32 }, (_, index) => (index === 7 ? 8 : index)),
          },
        ],
      }),
    };
    const bundle = decodeRuntimeAssets(
      {
        hero: { kind: 'sprite', path: 'hero.pxg' },
        tiles: { kind: 'tile_set', path: 'tiles.pxg' },
        room: { kind: 'map', path: 'room.pxm' },
        beep: { kind: 'sound', path: 'beep.pxs' },
        theme: { kind: 'music', path: 'theme.pxt' },
      },
      files,
      'display.pxp',
    );
    expect(bundle.visual.map((asset) => asset.kind)).toEqual(['sprite', 'map', 'tile_set']);
    expect(bundle.audio.map((asset) => asset.kind)).toEqual(['sound', 'music']);
    expect(bundle.maps[0]?.layers[0]?.tileFlags[0]).toBe(1);
    expect(bundle.visualBytes).toBeGreaterThan(0);
    const frame = new IndexedGraphics(
      new VisualAssetStore(bundle.visual),
      bundle.display,
    ).executeFrame([{ name: 'clear', arguments: [1], sourceSpan: { start: 0, end: 0 } }]);
    expect(frame.indexedPixels[0]).toBe(7);
    expect(frame.indexedPixels[240]).toBe(8);
  });

  it('rejects invalid palette indices and tracker references', () => {
    expect(() =>
      decodeRuntimeAssets(
        { hero: { kind: 'sprite', path: 'hero.pxg' } },
        {
          'hero.pxg': encodeAssetFile({
            revision: 1,
            kind: 'sprite',
            width: 1,
            height: 1,
            frames: [[32]],
          }),
        },
      ),
    ).toThrow(/indexed pixels/);
    expect(() =>
      decodeRuntimeAssets(
        { theme: { kind: 'music', path: 'theme.pxt' } },
        {
          'theme.pxt': encodeAssetFile({
            revision: 1,
            kind: 'music',
            framesPerRow: 4,
            order: ['a'],
            patterns: {
              a: {
                rows: [[{ note: 60, sound: 'missing' }, null, null, null, null, null, null, null]],
              },
            },
            loop: true,
          }),
        },
      ),
    ).toThrow(/missing sound/);
  });
});
