import { describe, expect, it } from 'vitest';

import { isMapQueryCatalog, MapQueryStore, type MapQueryAsset } from './map-query';

const level: MapQueryAsset = {
  name: 'level',
  layers: [
    {
      width: 2,
      height: 2,
      cells: Uint16Array.of(0, 1, 1, 0),
      tileFlags: Uint8Array.of(0b1, 0b10),
    },
  ],
};

describe('bounded worker map queries', () => {
  it('returns tile indices, flags, and safe out-of-bounds sentinels', () => {
    const maps = new MapQueryStore([level]);
    expect(maps.cell('level', 0, 1, 0)).toBe(1);
    expect(maps.flag('level', 0, 1, 0, 1)).toBe(true);
    expect(maps.flag('level', 0, 1, 0, 0)).toBe(false);
    expect(maps.cell('level', 0, -1, 0)).toBe(-1);
    expect(maps.cell('missing', 0, 0, 0)).toBe(-1);
  });

  it('validates structured-clone-compatible map catalogs', () => {
    expect(isMapQueryCatalog([level])).toBe(true);
    expect(isMapQueryCatalog([{ ...level, layers: [{ ...level.layers[0], cells: [0, 1] }] }])).toBe(
      false,
    );
    expect(
      () =>
        new MapQueryStore([
          {
            name: 'bad',
            layers: [
              { width: 1, height: 1, cells: Uint16Array.of(2), tileFlags: Uint8Array.of(0) },
            ],
          },
        ]),
    ).toThrow(/incoherent/);
  });
});
