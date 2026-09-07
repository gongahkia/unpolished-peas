import { describe, expect, it } from 'vitest';

import { DeterministicRng } from './rng';

describe('DeterministicRng', () => {
  it('matches the frozen xorshift32 sequence', () => {
    const rng = new DeterministicRng(0x240c1999);
    expect(Array.from({ length: 5 }, () => rng.nextU32())).toEqual([
      1_087_515_334, 3_034_048_611, 1_924_021_582, 368_270_957, 3_118_919_474,
    ]);
  });

  it('restores exactly and rejects incoherent ranges', () => {
    const rng = new DeterministicRng(7);
    const state = rng.state;
    const first = rng.nextInt(-4, 9);
    rng.restore(state);
    expect(rng.nextInt(-4, 9)).toBe(first);
    expect(() => rng.nextInt(3, 3)).toThrow(RangeError);
  });
});
