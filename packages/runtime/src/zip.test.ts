import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';

import { encodeSingleFileZip } from './zip';

describe('deterministic offline ZIP', () => {
  it('stores one byte-exact index without timestamps', () => {
    const contents = new TextEncoder().encode('<!doctype html><title>PX</title>');
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
      'cd29362199db5175e8d1a169d5a969809745eef09f4a735f218f2696cc896871',
    );
  });

  it('rejects unsafe names and oversized entries', () => {
    expect(() => encodeSingleFileZip('../index.html', new Uint8Array())).toThrow(/name/);
    expect(() => encodeSingleFileZip('index.html', new Uint8Array(32 * 1024 * 1024 + 1))).toThrow(
      /large/,
    );
  });
});
