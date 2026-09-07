import { describe, expect, it } from 'vitest';

import { emptyInputFrame } from './input';
import {
  DeterministicMachine,
  type CartridgeApi,
  type CartridgeFactory,
  type CartridgeSnapshot,
} from './machine';

interface TestState {
  value: number;
}

const counterFactory: CartridgeFactory = (api: CartridgeApi) => {
  const state: TestState = { value: 0 };
  return {
    start(): void {
      api.work(1, { start: 0, end: 5 });
      state.value = api.call('rng_int', [0, 100], { start: 6, end: 12 }) as number;
    },
    update(): void {
      api.work(3, { start: 20, end: 30 });
      state.value += api.call('rng_int', [0, 10], { start: 31, end: 40 }) as number;
    },
    draw(): void {
      api.work(2, { start: 50, end: 60 });
    },
    raster(line: number): void {
      if (line === 0) {
        api.work(1, { start: 70, end: 80 });
      }
    },
    snapshot(): CartridgeSnapshot {
      return { state: { ...state }, tasks: [], nextTaskId: 1 };
    },
    restore(snapshot: CartridgeSnapshot): void {
      const restored = snapshot.state as TestState;
      state.value = restored.value;
    },
    inspect() {
      return { state, tasks: [], callStack: [] };
    },
  };
};

describe('DeterministicMachine', () => {
  it('derives time from frames, respects 30 Hz update cadence, and restores RNG/state', () => {
    const machine = new DeterministicMachine(counterFactory, {
      seed: 9,
      workUnitsPerFrame: 100,
      updateRate: 30,
    });
    const frame0 = machine.runFrame(emptyInputFrame());
    expect(frame0).toMatchObject({ frame: 0, workUnits: 6 });
    expect(machine.cartridgeTimeSeconds).toBe(1 / 60);
    const snapshot = machine.snapshot();

    const frame1 = machine.runFrame(emptyInputFrame());
    const afterFrame1 = structuredClone(machine.inspect());
    expect(frame1.workUnits).toBe(3);

    machine.restore(snapshot);
    const replayedFrame1 = machine.runFrame(emptyInputFrame());
    expect(replayedFrame1).toEqual(frame1);
    expect(machine.inspect()).toEqual(afterFrame1);
  });
});
