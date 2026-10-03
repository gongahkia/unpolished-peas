import { describe, expect, it } from 'vitest';

import {
  CART_FRAGMENT_BYTE_LIMIT,
  CART_FRAGMENT_LIMIT,
  decodeCartridgeFragment,
  encodeCartridgeFragment,
} from './fragment';

describe('tiny cartridge URL fragments', () => {
  it('round-trips bytes using a fragment-only base64url form', () => {
    const bytes = Uint8Array.of(77, 79, 68, 45, 48, 49, 0, 255);
    const fragment = encodeCartridgeFragment(bytes);
    expect(fragment).toMatch(/^#m01c=[A-Za-z0-9_-]+$/);
    expect(fragment).not.toContain('?');
    expect(decodeCartridgeFragment(fragment)).toEqual(bytes);
    expect(decodeCartridgeFragment('#embed')).toBeUndefined();
  });

  it('rejects oversize and malformed fragment input before decoding', () => {
    expect(() => encodeCartridgeFragment(new Uint8Array(CART_FRAGMENT_BYTE_LIMIT + 1))).toThrow(
      /6000-byte/,
    );
    expect(() => decodeCartridgeFragment(`#m01c=${'A'.repeat(CART_FRAGMENT_LIMIT)}`)).toThrow(
      /long/,
    );
    expect(() => decodeCartridgeFragment('#m01c=../bad')).toThrow(/encoding/);
  });
});
