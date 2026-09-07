import { BudgetExceeded } from './errors';
import type { SourceSpan } from './protocol';

export interface WorkAttribution {
  readonly sourceSpan: SourceSpan;
  readonly units: number;
}

/** Per-frame synthetic execution budget and source-span attribution. */
export class WorkBudget {
  private readonly frameLimit: number;
  private usedUnits = 0;
  private readonly bySpan = new Map<string, WorkAttribution>();

  public constructor(frameLimit: number) {
    if (!Number.isSafeInteger(frameLimit) || frameLimit <= 0) {
      throw new RangeError('work-unit limit must be a positive safe integer');
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

  public charge(units: number, sourceSpan: SourceSpan): void {
    if (!Number.isSafeInteger(units) || units < 0) {
      throw new RangeError('work-unit charge must be a non-negative safe integer');
    }
    this.usedUnits += units;
    const key = `${String(sourceSpan.start)}:${String(sourceSpan.end)}`;
    const previous = this.bySpan.get(key);
    this.bySpan.set(key, {
      sourceSpan,
      units: (previous?.units ?? 0) + units,
    });
    if (this.usedUnits > this.frameLimit) {
      throw new BudgetExceeded(this.usedUnits, this.frameLimit, sourceSpan);
    }
  }

  public attribution(): readonly WorkAttribution[] {
    return [...this.bySpan.values()].sort(
      (left, right) => right.units - left.units || left.sourceSpan.start - right.sourceSpan.start,
    );
  }
}
