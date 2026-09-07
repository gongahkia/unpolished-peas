const NON_ZERO_FALLBACK = 0x240c1999;

/** Console-owned xorshift32 stream with an explicit serializable state. */
export class DeterministicRng {
  private current: number;

  public constructor(seed = NON_ZERO_FALLBACK) {
    this.current = normalizeSeed(seed);
  }

  public get state(): number {
    return this.current >>> 0;
  }

  public restore(state: number): void {
    this.current = normalizeSeed(state);
  }

  public nextU32(): number {
    let value = this.current >>> 0;
    value ^= value << 13;
    value ^= value >>> 17;
    value ^= value << 5;
    this.current = value >>> 0;
    return this.current;
  }

  public nextNum(): number {
    return this.nextU32() / 0x1_0000_0000;
  }

  public nextInt(minimum: number, maximumExclusive: number): number {
    if (
      !Number.isSafeInteger(minimum) ||
      !Number.isSafeInteger(maximumExclusive) ||
      maximumExclusive <= minimum
    ) {
      throw new RangeError('rng_int bounds must be safe integers with maximum greater than minimum');
    }
    const range = maximumExclusive - minimum;
    if (range > 0x1_0000_0000) {
      throw new RangeError('rng_int range must not exceed 2^32');
    }
    const rejectionLimit = 0x1_0000_0000 - (0x1_0000_0000 % range);
    let sample: number;
    do {
      sample = this.nextU32();
    } while (sample >= rejectionLimit);
    return minimum + (sample % range);
  }
}

function normalizeSeed(seed: number): number {
  if (!Number.isSafeInteger(seed)) {
    throw new RangeError('RNG seed must be a safe integer');
  }
  const normalized = seed >>> 0;
  return normalized === 0 ? NON_ZERO_FALLBACK : normalized;
}
