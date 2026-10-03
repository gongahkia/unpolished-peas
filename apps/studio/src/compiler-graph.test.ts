import { describe, expect, it } from 'vitest';

import { deriveCodeStateGraph } from './compiler-graph';
import type { CompilationResult } from './compiler';

describe('compiler-derived code/state graph', () => {
  it('derives reads, writes, and calls from typed IR instead of editor scene data', () => {
    const compilation = {
      analysis: {
        tokens: [],
        module: {},
        diagnostics: [],
        symbols: [
          {
            id: 1,
            name: 'score',
            kind: 'state',
            type: 'Int',
            mutable: true,
            defined_at: { file: 0, start: 0, end: 5 },
          },
          {
            id: 2,
            name: 'tick',
            kind: 'function',
            type: 'Unit',
            mutable: false,
            defined_at: { file: 0, start: 6, end: 10 },
          },
        ],
        ir: {
          globals: [],
          routines: [
            {
              symbol: 2,
              body: [
                { kind: 'Expression', data: { kind: 'Load', data: 1 } },
                { kind: 'Store', data: { target: { kind: 'Symbol', data: 1 } } },
                { kind: 'Expression', data: { kind: 'Call', data: { callee: 2 } } },
              ],
            },
          ],
        },
      },
      generated: { relationships: [{}, {}] },
    } as unknown as CompilationResult;
    expect(deriveCodeStateGraph(compilation)).toEqual({
      nodes: [
        { id: 2, label: 'tick', kind: 'function' },
        { id: 1, label: 'score', kind: 'state' },
      ],
      edges: [
        { from: 2, to: 1, relation: 'reads' },
        { from: 2, to: 1, relation: 'writes' },
        { from: 2, to: 2, relation: 'calls' },
      ],
      generatedMappings: 2,
    });
  });
});
