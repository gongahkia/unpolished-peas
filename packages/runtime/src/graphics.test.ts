import { describe, expect, it } from 'vitest';

import {
  IndexedGraphics,
  VisualAssetStore,
  orderedDither,
  type IndexedMap,
  type IndexedSprite,
  type IndexedTileSet,
} from './graphics';
import { HARDWARE, MASTER_PALETTE } from './hardware';
import type { ConsoleCommand } from './protocol';

const sourceSpan = { start: 0, end: 1 };

function command(
  name: string,
  arguments_: readonly unknown[],
  rasterLine?: number,
): ConsoleCommand {
  return {
    name,
    arguments: arguments_,
    sourceSpan,
    ...(rasterLine === undefined ? {} : { rasterLine }),
  };
}

describe('indexed graphics hardware', () => {
  it('uses one immutable, unique 32-colour master palette', () => {
    expect(MASTER_PALETTE).toHaveLength(HARDWARE.paletteSize);
    expect(new Set(MASTER_PALETTE)).toHaveLength(HARDWARE.paletteSize);
    expect(Object.isFrozen(MASTER_PALETTE)).toBe(true);
  });

  it('rasterizes primitives with camera, clipping, and logical palette remapping', () => {
    const graphics = new IndexedGraphics();
    const frame = graphics.executeFrame([
      command('clear', [1]),
      command('pal', [2, 11]),
      command('camera', [4, 3]),
      command('clip', [2, 2, 8, 8]),
      command('pixel', [6, 5, 2]),
      command('line', [6, 6, 9, 6, 3]),
      command('rect_fill', [6, 7, 2, 2, 4]),
      command('circle_fill', [10, 9, 1, 5]),
      command('triangle', [6, 10, 8, 10, 6, 12, 6]),
    ]);
    expect(frame.commands).toBe(9);
    expect(frame.indexedPixels[2 * HARDWARE.width + 2]).toBe(11);
    expect(frame.indexedPixels[3 * HARDWARE.width + 4]).toBe(3);
    expect(frame.indexedPixels[4 * HARDWARE.width + 2]).toBe(4);
    expect(frame.indexedPixels[6 * HARDWARE.width + 6]).toBe(5);
    expect(frame.indexedPixels[7 * HARDWARE.width + 2]).toBe(6);
    expect(frame.indexedPixels[0]).toBe(1);
  });

  it('applies scanline scroll and palette state only during display resolution', () => {
    const graphics = new IndexedGraphics();
    const frame = graphics.executeFrame([
      command('clear', [1]),
      command('pixel', [1, 0, 3]),
      command('raster_scroll', [1, 0], 0),
      command('pal', [3, 12], 0),
    ]);
    expect(frame.indexedPixels[0]).toBe(12);
    expect(frame.indexedPixels[HARDWARE.width]).toBe(1);

    const persistent = graphics.executeFrame([]);
    expect(persistent.indexedPixels[1]).toBe(3);
  });

  it('restores persistent and resolved framebuffer state', () => {
    const graphics = new IndexedGraphics();
    graphics.executeFrame([command('clear', [3]), command('pal', [3, 12], 0)]);
    const snapshot = graphics.snapshot();
    graphics.executeFrame([command('clear', [7])]);
    graphics.restore(snapshot);

    expect(graphics.snapshot()).toEqual(snapshot);
    expect(graphics.executeFrame([]).indexedPixels[0]).toBe(3);
  });

  it('draws transparent sprites, transforms, tile maps, and bounded tile flags', () => {
    const sprite: IndexedSprite = {
      kind: 'sprite',
      name: 'hero',
      width: 2,
      height: 2,
      pixels: Uint8Array.of(2, 3, 0, 4),
    };
    const tile: IndexedSprite = {
      kind: 'sprite',
      name: 'ground-tile',
      width: 8,
      height: 8,
      pixels: new Uint8Array(64).fill(6),
    };
    const tileSet: IndexedTileSet = {
      kind: 'tile_set',
      name: 'ground',
      tiles: [tile],
      flags: Uint8Array.of(0b10),
    };
    const map: IndexedMap = {
      kind: 'map',
      name: 'level',
      layers: [{ width: 1, height: 1, cells: Uint16Array.of(0), tileSet: 'ground' }],
    };
    const assets = new VisualAssetStore([sprite, tileSet, map]);
    const graphics = new IndexedGraphics(assets);
    const frame = graphics.executeFrame([
      command('clear', [1]),
      command('sprite', [{ name: 'hero', kind: 'Sprite' }, 1, 1]),
      command('sprite_xform', [{ name: 'hero', kind: 'Sprite' }, 4, 1, 2, 1, false, false]),
      command('map', [{ name: 'level', kind: 'Map' }, 10, 1]),
    ]);
    expect(frame.indexedPixels[1 * HARDWARE.width + 1]).toBe(2);
    expect(frame.indexedPixels[2 * HARDWARE.width + 1]).toBe(1);
    expect(frame.indexedPixels[3 * HARDWARE.width + 4]).toBe(4);
    expect(frame.indexedPixels[1 * HARDWARE.width + 10]).toBe(6);
    expect(assets.mapCell('level', 0, 0, 0)).toBe(0);
    expect(assets.mapCell('level', 0, 1, 0)).toBeUndefined();
    expect(assets.mapFlag('level', 0, 0, 0, 1)).toBe(true);
  });

  it('enforces asset, sprite, palette, transform, and command limits', () => {
    const maximum = new Uint8Array(HARDWARE.spriteMaximumAxis ** 2);
    const assets = Array.from({ length: 33 }, (_, index): IndexedSprite => ({
      kind: 'sprite',
      name: `sprite-${String(index)}`,
      width: HARDWARE.spriteMaximumAxis,
      height: HARDWARE.spriteMaximumAxis,
      pixels: maximum,
    }));
    expect(() => new VisualAssetStore(assets)).toThrow(/128 KiB/);
    expect(() => new IndexedGraphics().executeFrame([command('clear', [32])])).toThrow(/0 and 31/);
    expect(() =>
      new IndexedGraphics(
        new VisualAssetStore([
          { kind: 'sprite', name: 'dot', width: 1, height: 1, pixels: Uint8Array.of(1) },
        ]),
      ).executeFrame([
        command('sprite_xform', [{ name: 'dot', kind: 'Sprite' }, 0, 0, 17, 0, false, false]),
      ]),
    ).toThrow(/between 1 and 16/);
    expect(() =>
      new IndexedGraphics().executeFrame(
        Array.from({ length: HARDWARE.drawCommandsPerFrame + 1 }, () =>
          command('pixel', [0, 0, 1]),
        ),
      ),
    ).toThrow(/ceiling/);
  });

  it('provides deterministic ordered dithering', () => {
    const pattern = Array.from({ length: 16 }, (_, index) =>
      orderedDither(index % 4, Math.floor(index / 4), 1, 2, 8),
    );
    expect(pattern.filter((color) => color === 2)).toHaveLength(8);
    expect(pattern).toEqual([2, 1, 2, 1, 1, 2, 1, 2, 2, 1, 2, 1, 1, 2, 1, 2]);
  });

  it('renders the built-in ASCII bitmap font into indexed pixels', () => {
    const frame = new IndexedGraphics().executeFrame([
      command('clear', [0]),
      command('print', ['A!', 0, 0, 7]),
    ]);
    expect(frame.indexedPixels[1]).toBe(7);
    expect(frame.indexedPixels[2]).toBe(7);
    expect(frame.indexedPixels[3]).toBe(7);
    expect(frame.indexedPixels[6 + 2]).toBe(7);
    expect(frame.indexedPixels[6 * HARDWARE.width + 6 + 2]).toBe(7);
  });
});
