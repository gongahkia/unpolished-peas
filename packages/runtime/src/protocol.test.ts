import { describe, expect, it } from 'vitest';

import { lockDownWorkerGlobals } from './capabilities';
import { emptyInputFrame } from './input';
import { isHostRequest } from './protocol';

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
});
