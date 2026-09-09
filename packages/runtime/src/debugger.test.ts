import { describe, expect, it } from 'vitest';

import {
  consoleReplayObservable,
  debugFingerprint,
  evaluateWatch,
  ReplayJournal,
} from './debugger';
import { createConsoleRuntime } from './console-runtime';
import { MEMORY } from './bus';
import { emptyInputFrame } from './input';

describe('debugger replay and watches', () => {
  it('detects pixel and PCM divergence even when bus code emits no draw or audio commands', async () => {
    const runtime = createConsoleRuntime(
      (api) => ({
        start() {},
        update() {},
        raster() {},
        draw() {
          api.call('mem_write', [MEMORY.back, 7], { start: 0, end: 1 });
        },
        snapshot: () => ({ state: {}, tasks: [], nextTaskId: 1 }),
        restore() {},
        inspect: () => ({ state: {}, tasks: [], callStack: [] }),
      }),
      { seed: 1, updateRate: 60, workUnitsPerFrame: 50_000 },
    );
    const journal = new ReplayJournal(4);
    journal.recordSnapshot(0, runtime.snapshot());
    const frame = runtime.runFrame(emptyInputFrame());
    expect(frame.drawCommands).toEqual([]);
    expect(frame.audioCommands).toEqual([]);
    journal.recordFrame(0, emptyInputFrame(), consoleReplayObservable(frame));
    for (const change of ['pixel', 'audio']) {
      const altered = structuredClone(frame);
      if (change === 'pixel') altered.output.indexedPixels[0] = 8;
      else altered.output.audio.left[0] = 0.5;
      const replay = await journal.replay(1, {
        restore: () => Promise.resolve(),
        frame: () => Promise.resolve(consoleReplayObservable(altered)),
      });
      expect(replay.divergence).toMatchObject({ frame: 0 });
    }
  });

  it('plans snapshot replay, detects divergence, and supports branching', async () => {
    const journal = new ReplayJournal(4);
    journal.recordSnapshot(0, { cursor: 0 });
    for (let frame = 0; frame < 5; frame += 1) {
      journal.recordFrame(frame, emptyInputFrame(), { frame, value: frame * 2 });
      if ((frame + 1) % 2 === 0) journal.recordSnapshot(frame + 1, { cursor: frame + 1 });
    }
    expect(journal.oldestFrame).toBe(0);
    const restored: unknown[] = [];
    const replayed = await journal.replay(3, {
      restore: (snapshot) => {
        restored.push(snapshot);
        return Promise.resolve();
      },
      frame: (input) => {
        expect(input).toEqual(emptyInputFrame());
        const frame = restored.length === 1 ? 2 : -1;
        restored.push(frame);
        return Promise.resolve({ frame, value: frame * 2 });
      },
    });
    expect(replayed).toEqual({ frame: 3 });
    expect(restored[0]).toEqual({ cursor: 2 });

    const diverged = await journal.replay(3, {
      restore: () => Promise.resolve(),
      frame: () => Promise.resolve({ frame: 2, value: 99 }),
    });
    expect(diverged.divergence).toMatchObject({ frame: 2 });

    journal.truncate(3);
    journal.recordFrame(3, emptyInputFrame(), { frame: 3, value: 7 });
    expect(journal.cursor).toBe(4);
    expect(journal.timeline()).toEqual([0, 1, 2, 3]);
  });

  it('fingerprints objects canonically and rejects cycles', () => {
    expect(debugFingerprint({ b: 2, a: Uint8Array.of(1) })).toBe(
      debugFingerprint({ a: Uint8Array.of(1), b: 2 }),
    );
    const cyclic: unknown[] = [];
    cyclic.push(cyclic);
    expect(() => debugFingerprint(cyclic)).toThrow(/cycle/);
  });

  it('evaluates a deliberately safe watch subset without calls or prototype access', () => {
    const environment = { score: 7, alive: true, hero: { x: 3 }, cells: [4, 9] };
    expect(evaluateWatch('alive and score >= hero.x + cells[0]', environment)).toBe(true);
    expect(evaluateWatch('not false and "PX" + "CL" == "PXCL"', environment)).toBe(true);
    expect(() => evaluateWatch('alert()', environment)).toThrow(/unknown watch name/);
    expect(() => evaluateWatch('hero.constructor', environment)).toThrow(/prototype/);
    expect(() => evaluateWatch('score = 2', environment)).toThrow(/unsupported watch token/);
  });
});
