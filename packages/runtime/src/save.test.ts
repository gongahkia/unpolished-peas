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
    expect(() => {
      save.set('__proto__', 1);
    }).toThrow(/canonical ASCII/);
    expect(() => {
      save.set('score', 0.5);
    }).toThrow(/safe integers/);
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

  it('validates pending writes and preserves them across snapshots without flushing early', () => {
    const save = new SaveMemory();
    save.set('score', 7);
    expect(save.pendingWrites()).toEqual([{ key: 'score', value: 7 }]);
    const snapshot = save.snapshot();
    expect(() => {
      save.restore({ score: 7 }, [{ key: 'score', value: 8 }]);
    }).toThrow(/snapshot/);
    expect(() => {
      save.restore({ score: 7 }, [
        { key: 'score', value: 7 },
        { key: 'score', value: 7 },
      ]);
    }).toThrow(/snapshot/);
    expect(save.snapshot()).toEqual(snapshot);
    expect(save.takeWrites()).toEqual([{ key: 'score', value: 7 }]);
  });
});
