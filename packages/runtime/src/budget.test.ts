import { describe, expect, it } from 'vitest';

import { WorkBudget } from './budget';
import { BudgetExceeded } from './errors';

describe('WorkBudget', () => {
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
