import { describe, expect, it } from 'vitest';

import { lockDownWorkerGlobals } from './capabilities';
import { emptyInputFrame } from './input';
import { isHostRequest, isWorkerResponse } from './protocol';

describe('sandbox protocol', () => {
  it('accepts complete frame messages and denies non-blob cartridge module URLs', () => {
    expect(isHostRequest({ id: 1, type: 'frame', input: emptyInputFrame() })).toBe(true);
    expect(
      isHostRequest({
        id: 2,
        type: 'load',
        moduleUrl: 'https://example.test/cartridge.js',
        configuration: { seed: 1, workUnitsPerFrame: 100, updateRate: 60 },
      }),
    ).toBe(false);
  });

  it('removes ambient network, time, storage, random and dynamic-code capabilities', () => {
    const target: Record<string, unknown> = {
      Date,
      fetch: () => undefined,
      WebSocket: () => undefined,
      indexedDB: {},
      crypto: {},
      eval,
      Function,
      Math,
    };
    lockDownWorkerGlobals(target);
    for (const name of ['Date', 'fetch', 'WebSocket', 'indexedDB', 'crypto', 'eval', 'Function']) {
      expect(target[name]).toBeUndefined();
    }
    expect(target.Math).toMatchObject({ max: Math.max, trunc: Math.trunc });
    expect(target.Math).not.toHaveProperty('random');
  });

  it('rejects shallow or over-specified worker responses', () => {
    const frame = {
      id: 1,
      type: 'frame',
      frame: 0,
      workUnits: 4,
      attribution: [{ sourceSpan: { start: 1, end: 2 }, units: 4 }],
      drawCommands: [
        { name: 'clear', arguments: [0], sourceSpan: { start: 1, end: 2 } },
        {
          name: 'pal',
          arguments: [1, 2],
          sourceSpan: { start: 3, end: 4 },
          rasterLine: 12,
        },
      ],
      audioCommands: [],
      saveWrites: [],
    };
    expect(isWorkerResponse(frame)).toBe(true);
    expect(
      isWorkerResponse({
        ...frame,
        debug: {
          truncated: false,
          trace: [
            {
              id: 0,
              sourceSpan: { start: 1, end: 2 },
              locals: { s1: 4 },
              callStack: [{ name: 'update', sourceSpan: { start: 0, end: 8 } }],
            },
          ],
          inspection: { state: { s0: 4 }, tasks: [], callStack: [] },
        },
      }),
    ).toBe(true);
    expect(isWorkerResponse({ id: 1, type: 'frame' })).toBe(false);
    expect(isWorkerResponse({ ...frame, ambient: true })).toBe(false);
    expect(isWorkerResponse({ ...frame, drawCommands: [{ name: 'clear' }] })).toBe(false);
    expect(isWorkerResponse({ ...frame, debug: { trace: [], inspection: {} } })).toBe(false);
  });
});
