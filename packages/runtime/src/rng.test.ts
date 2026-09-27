import { describe, expect, it } from 'vitest';

import { DeterministicRng } from './rng';

describe('DeterministicRng', () => {
  it('matches the frozen xorshift32 sequence', () => {
    const rng = new DeterministicRng(0x4d30_3031);
    expect(Array.from({ length: 5 }, () => rng.nextU32())).toEqual([
      770_736_362, 2_153_127_324, 1_062_351_278, 1_436_446_397, 2_440_679_865,
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
