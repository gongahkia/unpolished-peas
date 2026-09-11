import { describe, expect, it } from 'vitest';

import { remapBreakpoints } from './debugger';

describe('debugger breakpoint persistence', () => {
  it('remaps anchored module breakpoints after lines move and rejects malformed storage', () => {
    const sources = new Map([
      [
        'src/math.pxl',
        'fn twice(value: Int) -> Int:\n\n  var result = value\n  result += value\n  return result\n',
      ],
    ]);
    expect(
      remapBreakpoints(
        {
          revision: 1,
          breakpoints: [
            {
              source: 'src/math.pxl',
              line: 3,
              condition: 'value > 0',
              anchor: 'result += value',
            },
            {
              source: 'src/missing.pxl',
              line: 1,
              condition: '',
              anchor: 'return 0',
            },
          ],
        },
        sources,
      ),
    ).toEqual([
      {
        source: 'src/math.pxl',
        line: 4,
        condition: 'value > 0',
        anchor: 'result += value',
      },
    ]);
    expect(remapBreakpoints({ revision: 2, breakpoints: [] }, sources)).toEqual([]);
    expect(
      remapBreakpoints(
        {
          revision: 1,
          breakpoints: [{ source: 'src/math.pxl', line: -1, condition: '', anchor: '' }],
        },
        sources,
      ),
    ).toEqual([]);
  });
});
