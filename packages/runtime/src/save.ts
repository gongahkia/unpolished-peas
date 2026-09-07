import { HARDWARE } from './hardware';

export type SaveValues = Readonly<Record<string, number>>;

export interface SaveWrite {
  readonly key: string;
  readonly value: number;
}

/** Serializable integer save state kept inside the worker and flushed by the trusted host. */
export class SaveMemory {
  private values: Record<string, number>;
  private readonly writes = new Map<string, number>();

  public constructor(initial: SaveValues = {}) {
    if (!isSaveValues(initial)) {
      throw new TypeError('invalid PX-240C save values');
    }
    this.values = { ...initial };
  }

  public get(key: string, fallback: number): number {
    validateKey(key);
    validateInteger(fallback);
    return this.values[key] ?? fallback;
  }

  public set(key: string, value: number): void {
    validateKey(key);
    validateInteger(value);
    const next = { ...this.values, [key]: value };
    if (encodedBytes(next) > HARDWARE.saveCapacityBytes) {
      throw new RangeError('cartridge save exceeds the 8 KiB capacity');
    }
    this.values = next;
    this.writes.set(key, value);
  }

  public snapshot(): SaveValues {
    return sortedValues(this.values);
  }

  public restore(value: unknown): void {
    if (!isSaveValues(value)) {
      throw new TypeError('invalid PX-240C save snapshot');
    }
    this.values = { ...value };
    this.writes.clear();
  }

  public takeWrites(): readonly SaveWrite[] {
    const result = [...this.writes]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, value]) => ({ key, value }));
    this.writes.clear();
    return result;
  }
}

export function isSaveValues(value: unknown): value is SaveValues {
  if (!isRecord(value) || Array.isArray(value)) {
    return false;
  }
  try {
    for (const [key, entry] of Object.entries(value)) {
      validateKey(key);
      validateInteger(entry);
    }
    return encodedBytes(value as SaveValues) <= HARDWARE.saveCapacityBytes;
  } catch {
    return false;
  }
}

function sortedValues(values: SaveValues): SaveValues {
  return Object.fromEntries(
    Object.entries(values).sort(([left], [right]) => left.localeCompare(right)),
  );
}

function encodedBytes(values: SaveValues): number {
  return new TextEncoder().encode(JSON.stringify(sortedValues(values))).byteLength;
}

function validateKey(key: string): void {
  if (
    !/^[A-Za-z_][A-Za-z0-9_.-]{0,63}$/.test(key) ||
    ['__proto__', 'constructor', 'prototype'].includes(key)
  ) {
    throw new TypeError('save keys must be 1-64 canonical ASCII characters');
  }
}

function validateInteger(value: unknown): asserts value is number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) {
    throw new TypeError('save values must be safe integers');
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
