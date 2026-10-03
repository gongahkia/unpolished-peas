import { BudgetExceeded } from './errors';
import { HARDWARE } from './hardware';
import type { SourceSpan } from './protocol';

export interface WorkAttribution {
  readonly sourceSpan: SourceSpan;
  readonly units: number;
}

export interface WorkBudgetSnapshot {
  readonly revision: 1;
  readonly limit: number;
  readonly used: number;
  readonly attribution: readonly WorkAttribution[];
}

export function isWorkBudgetSnapshot(value: unknown): value is WorkBudgetSnapshot {
  if (
    !isRecord(value) ||
    Object.keys(value).length !== 4 ||
    value.revision !== 1 ||
    typeof value.limit !== 'number' ||
    !Number.isSafeInteger(value.limit) ||
    value.limit < 1 ||
    value.limit > HARDWARE.workUnitsPerFrame ||
    typeof value.used !== 'number' ||
    !Number.isSafeInteger(value.used) ||
    value.used < 0 ||
    !Array.isArray(value.attribution) ||
    value.attribution.length > HARDWARE.workUnitsPerFrame + 1
  )
    return false;
  let total = 0;
  let previousUnits = Infinity;
  let previousStart = -1;
  const spans = new Set<string>();
  for (const entry of value.attribution as unknown[]) {
    if (
      !isRecord(entry) ||
      Object.keys(entry).length !== 2 ||
      typeof entry.units !== 'number' ||
      !Number.isSafeInteger(entry.units) ||
      entry.units < 0 ||
      entry.units > value.used - total ||
      !isRecord(entry.sourceSpan) ||
      Object.keys(entry.sourceSpan).length !== 2 ||
      typeof entry.sourceSpan.start !== 'number' ||
      !Number.isSafeInteger(entry.sourceSpan.start) ||
      entry.sourceSpan.start < 0 ||
      typeof entry.sourceSpan.end !== 'number' ||
      !Number.isSafeInteger(entry.sourceSpan.end) ||
      entry.sourceSpan.end < entry.sourceSpan.start ||
      entry.units > previousUnits ||
      (entry.units === previousUnits && entry.sourceSpan.start < previousStart)
    )
      return false;
    const key = `${String(entry.sourceSpan.start)}:${String(entry.sourceSpan.end)}`;
    if (spans.has(key)) return false;
    spans.add(key);
    total += entry.units;
    previousUnits = entry.units;
    previousStart = entry.sourceSpan.start;
  }
  return total === value.used;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** Per-frame synthetic execution budget and source-span attribution. */
export class WorkBudget {
  private readonly frameLimit: number;
  private usedUnits = 0;
  private readonly bySpan = new Map<string, WorkAttribution>();

  public constructor(frameLimit: number) {
    if (
      !Number.isSafeInteger(frameLimit) ||
      frameLimit <= 0 ||
      frameLimit > HARDWARE.workUnitsPerFrame
    ) {
      throw new RangeError('work-unit limit must be an integer between 1 and 50,000');
    }
    this.frameLimit = frameLimit;
  }

  public get limit(): number {
    return this.frameLimit;
  }

  public get used(): number {
    return this.usedUnits;
  }

  public beginFrame(): void {
    this.usedUnits = 0;
    this.bySpan.clear();
  }

  public snapshot(): WorkBudgetSnapshot {
    return structuredClone({
      revision: 1,
      limit: this.frameLimit,
      used: this.usedUnits,
      attribution: this.attribution(),
    });
  }

  public restore(value: unknown): void {
    if (!isWorkBudgetSnapshot(value) || value.limit !== this.frameLimit)
      throw new TypeError('invalid or mismatched work-budget snapshot');
    const entries = structuredClone(value.attribution);
    this.usedUnits = value.used;
    this.bySpan.clear();
    for (const entry of entries)
      this.bySpan.set(`${String(entry.sourceSpan.start)}:${String(entry.sourceSpan.end)}`, entry);
  }

  public charge(units: number, sourceSpan: SourceSpan): void {
    if (!Number.isInteger(units) || units < 0) {
      throw new RangeError('work-unit charge must be a non-negative finite integer');
    }
    // faulted counters saturate instead of producing unsafe integer snapshots.
    const charged = Math.min(units, Number.MAX_SAFE_INTEGER - this.usedUnits);
    this.usedUnits += charged;
    const key = `${String(sourceSpan.start)}:${String(sourceSpan.end)}`;
    const previous = this.bySpan.get(key);
    this.bySpan.set(key, {
      sourceSpan,
      units: (previous?.units ?? 0) + charged,
    });
    if (charged !== units || this.usedUnits > this.frameLimit) {
      throw new BudgetExceeded(this.usedUnits, this.frameLimit, sourceSpan);
    }
  }

  public attribution(): readonly WorkAttribution[] {
    return [...this.bySpan.values()].sort(
      (left, right) => right.units - left.units || left.sourceSpan.start - right.sourceSpan.start,
    );
  }
}
