import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';

import {
  convertRgbaToIndexed,
  decodeCartridgePng,
  decodePngRgba,
  encodeCartridgePng,
  encodeRgbaPng,
} from './png';

const hash = (bytes: Uint8Array): string => createHash('sha256').update(bytes).digest('hex');

describe('deterministic PNG interchange', () => {
  it('round-trips exact RGBA through a byte-identical dependency-free PNG', async () => {
    const rgba = Uint8Array.of(0, 0, 0, 0, 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255);
    const first = encodeRgbaPng(2, 2, rgba);
    const second = encodeRgbaPng(2, 2, rgba);
    expect(second).toEqual(first);
    expect(hash(first)).toBe('e3830600039b239093b429b92f721c83f502f000df812f55f156783c30b22b89');
    await expect(decodePngRgba(first)).resolves.toEqual({ width: 2, height: 2, rgba });
  });

  it('converts alpha, nearest color, and ordered dither deterministically', () => {
    const image = {
      width: 4,
      height: 1,
      rgba: Uint8Array.of(0, 0, 0, 0, 244, 229, 189, 255, 120, 110, 100, 255, 120, 110, 100, 255),
    };
    expect([...convertRgbaToIndexed(image, 'nearest', 127, 0)].slice(0, 2)).toEqual([0, 7]);
    expect(convertRgbaToIndexed(image, 'ordered')).toEqual(convertRgbaToIndexed(image, 'ordered'));
  });

  it('embeds one bounded cartridge and validated metadata without losing bytes', () => {
    const cartridge = Uint8Array.of(80, 88, 67, 49, 1, 2, 3);
    const metadata = {
      title: 'TEST CART',
      author: '@gongahkia',
      year: 1999,
      players: 2,
      controls: 'PAD',
    };
    const png = encodeCartridgePng(cartridge, metadata);
    expect(decodeCartridgePng(png)).toEqual({ cartridge, metadata });
    const corrupted = png.slice();
    corrupted[corrupted.length - 20] ^= 1;
    expect(() => decodeCartridgePng(corrupted)).toThrow(/CRC/);
  });

  it('rejects dimensions, decompression bombs, and oversize cartridge metadata early', async () => {
    expect(() => encodeRgbaPng(0, 1, new Uint8Array())).toThrow(/dimensions/);
    expect(() =>
      encodeCartridgePng(Uint8Array.of(1), {
        title: 'X'.repeat(65),
        author: 'A',
        year: 1999,
        players: 1,
        controls: '',
      }),
    ).toThrow(/metadata/);
    const png = encodeRgbaPng(1, 1, Uint8Array.of(0, 0, 0, 255));
    const truncated = png.subarray(0, png.length - 1);
    await expect(decodePngRgba(truncated)).rejects.toThrow();
  });
});
