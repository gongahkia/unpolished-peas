import { describe, expect, it } from 'vitest';

import {
  CART_FRAGMENT_BYTE_LIMIT,
  CART_FRAGMENT_LIMIT,
  decodeCartridgeFragment,
  encodeCartridgeFragment,
} from './fragment';

describe('tiny cartridge URL fragments', () => {
  it('round-trips bytes using a fragment-only base64url form', () => {
    const bytes = Uint8Array.of(80, 88, 50, 52, 48, 67, 0, 255);
    const fragment = encodeCartridgeFragment(bytes);
    expect(fragment).toMatch(/^#pxc=[A-Za-z0-9_-]+$/);
    expect(fragment).not.toContain('?');
    expect(decodeCartridgeFragment(fragment)).toEqual(bytes);
    expect(decodeCartridgeFragment('#embed')).toBeUndefined();
  });

  it('rejects oversize and malformed fragment input before decoding', () => {
    expect(() => encodeCartridgeFragment(new Uint8Array(CART_FRAGMENT_BYTE_LIMIT + 1))).toThrow(
      /6000-byte/,
    );
    expect(() => decodeCartridgeFragment(`#pxc=${'A'.repeat(CART_FRAGMENT_LIMIT)}`)).toThrow(
      /long/,
    );
    expect(() => decodeCartridgeFragment('#pxc=../bad')).toThrow(/encoding/);
  });
});
