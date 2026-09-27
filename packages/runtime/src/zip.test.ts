import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';

import { encodeSingleFileZip } from './zip';

describe('deterministic offline ZIP', () => {
  it('stores one byte-exact index without timestamps', () => {
    const contents = new TextEncoder().encode('<!doctype html><title>MOD-01</title>');
    const zip = encodeSingleFileZip('index.html', contents);
    expect(encodeSingleFileZip('index.html', contents)).toEqual(zip);
    const view = new DataView(zip.buffer);
    expect(view.getUint32(0, true)).toBe(0x04034b50);
    const nameLength = view.getUint16(26, true);
    const start = 30 + nameLength;
    expect(zip.subarray(start, start + contents.length)).toEqual(contents);
    expect(view.getUint16(10, true)).toBe(0);
    expect(view.getUint16(12, true)).toBe(0);
    expect(createHash('sha256').update(zip).digest('hex')).toBe(
      'b647bc4ec6490b6521bcae10ba0e1529561a54ea11dd2d5eccaf3bf24c969b52',
    );
  });

  it('rejects unsafe names and oversized entries', () => {
    expect(() => encodeSingleFileZip('../index.html', new Uint8Array())).toThrow(/name/);
    expect(() => encodeSingleFileZip('index.html', new Uint8Array(32 * 1024 * 1024 + 1))).toThrow(
      /large/,
    );
  });
});
