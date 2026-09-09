import { describe, expect, it } from 'vitest';

import { WorkBudget, isWorkBudgetSnapshot } from './budget';
import { BudgetExceeded } from './errors';

describe('WorkBudget', () => {
  it('restores complete work accounting and rejects mismatched or malformed snapshots transactionally', () => {
    const budget = new WorkBudget(10);
    budget.charge(4, { start: 20, end: 25 });
    budget.charge(3, { start: 2, end: 6 });
    const saved = budget.snapshot();
    expect(isWorkBudgetSnapshot(saved)).toBe(true);
    expect(saved).toEqual({
      revision: 1,
      limit: 10,
      used: 7,
      attribution: [
        { sourceSpan: { start: 20, end: 25 }, units: 4 },
        { sourceSpan: { start: 2, end: 6 }, units: 3 },
      ],
    });
    expect(() => {
      budget.charge(4, { start: 30, end: 31 });
    }).toThrow(BudgetExceeded);
    budget.restore(saved);
    expect(budget.snapshot()).toEqual(saved);
    for (const invalid of [
      { ...saved, used: 8 },
      { ...saved, limit: 11 },
      { ...saved, extra: true },
      { ...saved, attribution: saved.attribution.toReversed() },
      { ...saved, attribution: Array(2) as unknown[] },
      { ...saved, used: 8, attribution: [saved.attribution[0], saved.attribution[0]] },
      { ...saved, used: 4, attribution: [{ sourceSpan: { start: 5, end: 4 }, units: 4 }] },
      { ...saved, attribution: [{ sourceSpan: { start: 0, end: 1 }, units: -1 }] },
    ]) {
      expect(() => {
        budget.restore(invalid);
      }).toThrow(/snapshot/);
      expect(budget.snapshot()).toEqual(saved);
    }
    budget.beginFrame();
    expect(budget.snapshot()).toEqual({ revision: 1, limit: 10, used: 0, attribution: [] });
  });

  it('keeps the hardware ceiling fixed and faulted counters representable for enormous charges', () => {
    for (const limit of [0, -1, 0.5, Infinity, 50_001, Number.MAX_SAFE_INTEGER])
      expect(() => new WorkBudget(limit)).toThrow(/50,000/);
    for (const units of [Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER ** 2]) {
      const budget = new WorkBudget(50_000);
      budget.charge(8, { start: 0, end: 1 });
      expect(() => {
        budget.charge(units, { start: 2, end: 3 });
      }).toThrow(expect.objectContaining({ code: 'PX9001', sourceSpan: { start: 2, end: 3 } }));
      expect(budget.used).toBe(Number.MAX_SAFE_INTEGER);
      expect(isWorkBudgetSnapshot(budget.snapshot())).toBe(true);
      const restored = new WorkBudget(50_000);
      restored.restore(budget.snapshot());
      expect(restored.snapshot()).toEqual(budget.snapshot());
    }
  });

  it('attributes work deterministically and stops at the source span that exceeds the frame', () => {
    const budget = new WorkBudget(10);
    budget.beginFrame();
    budget.charge(4, { start: 20, end: 25 });
    budget.charge(3, { start: 2, end: 6 });
    budget.charge(2, { start: 20, end: 25 });
    expect(budget.attribution()).toEqual([
      { sourceSpan: { start: 20, end: 25 }, units: 6 },
      { sourceSpan: { start: 2, end: 6 }, units: 3 },
    ]);
    expect(() => {
      budget.charge(2, { start: 90, end: 99 });
    }).toThrow(BudgetExceeded);
    try {
      budget.charge(1, { start: 100, end: 101 });
    } catch (error: unknown) {
      expect(error).toMatchObject({
        code: 'PX9001',
        sourceSpan: { start: 100, end: 101 },
        limit: 10,
      });
    }
  });
});
