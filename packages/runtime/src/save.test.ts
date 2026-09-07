import { describe, expect, it } from 'vitest';

import { HARDWARE } from './hardware';
import { isSaveValues, SaveMemory } from './save';

describe('worker save memory', () => {
  it('reads fallbacks, emits sorted writes, and restores snapshots', () => {
    const save = new SaveMemory({ score: 2 });
    expect(save.get('score', 0)).toBe(2);
    expect(save.get('missing', 7)).toBe(7);
    save.set('z_value', 4);
    save.set('a_value', 3);
    expect(save.takeWrites()).toEqual([
      { key: 'a_value', value: 3 },
      { key: 'z_value', value: 4 },
    ]);
    const snapshot = save.snapshot();
    save.set('score', 9);
    save.restore(snapshot);
    expect(save.get('score', 0)).toBe(2);
    expect(save.takeWrites()).toEqual([]);
  });

  it('rejects unsafe keys, non-integers, and save-capacity overflow', () => {
    const save = new SaveMemory();
    expect(() => save.set('__proto__', 1)).toThrow(/canonical ASCII/);
    expect(() => save.set('score', 0.5)).toThrow(/safe integers/);
    const oversized = Object.fromEntries(
      Array.from({ length: 512 }, (_, index) => [
        `value_${String(index)}`,
        Number.MAX_SAFE_INTEGER,
      ]),
    );
    expect(new TextEncoder().encode(JSON.stringify(oversized)).byteLength).toBeGreaterThan(
      HARDWARE.saveCapacityBytes,
    );
    expect(isSaveValues(oversized)).toBe(false);
  });
});
