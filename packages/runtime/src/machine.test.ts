import { describe, expect, it } from 'vitest';

import { emptyInputFrame } from './input';
import {
  DeterministicMachine,
  type CartridgeApi,
  type CartridgeFactory,
  type CartridgeSnapshot,
  type ExecutionContext,
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
  it('samples button edges per display frame, including skipped 30 Hz updates', () => {
    const updates: unknown[] = [];
    const draws: unknown[] = [];
    const span = { start: 4, end: 9 };
    const machine = new DeterministicMachine(
      (api) => ({
        ...counterFactory(api),
        update() {
          updates.push([
            machine.frame,
            api.call('btn', [0, 'a'], span),
            api.call('btnp', [0, 'a'], span),
          ]);
        },
        draw() {
          draws.push([
            machine.frame,
            api.call('btn', [0, 'a'], span),
            api.call('btnp', [0, 'a'], span),
          ]);
        },
      }),
      { seed: 1, updateRate: 30, workUnitsPerFrame: 100 },
    );
    const released = emptyInputFrame();
    const held = {
      ...released,
      controllers: [
        { buttons: { ...released.controllers[0].buttons, a: true } },
        released.controllers[1],
        released.controllers[2],
        released.controllers[3],
      ] as const,
    };
    machine.runFrame(released);
    machine.runFrame(held);
    const skipped = machine.snapshot();
    machine.runFrame(held);
    machine.runFrame(released);
    machine.runFrame(released);
    expect(updates).toEqual([
      [0, false, false],
      [2, true, false],
      [4, false, false],
    ]);
    expect(draws).toEqual([
      [0, false, false],
      [1, true, true],
      [2, true, false],
      [3, false, false],
      [4, false, false],
    ]);
    machine.restore(skipped);
    machine.runFrame(held);
    expect(updates.at(-1)).toEqual([2, true, false]);
  });

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

  it('reports callback phase/scanline context and evaluates dithering inside the machine', () => {
    const contexts: ExecutionContext[] = [];
    const factory: CartridgeFactory = (api) => ({
      start: () => void api.call('trace', [], { start: 0, end: 1 }),
      update: () => undefined,
      draw: () => void api.call('trace', [], { start: 2, end: 3 }),
      raster: (line) => {
        if (line === 7) {
          api.call('trace', [], { start: 4, end: 5 });
        }
      },
      snapshot: () => ({ state: {}, tasks: [], nextTaskId: 1 }),
      restore: () => undefined,
      inspect: () => ({ state: {}, tasks: [], callStack: [] }),
    });
    const machine = new DeterministicMachine(
      factory,
      { seed: 1, workUnitsPerFrame: 100, updateRate: 60 },
      {
        call: (_name, _arguments, _span, context) => {
          contexts.push(context);
          return undefined;
        },
      },
    );
    machine.runFrame(emptyInputFrame());
    expect(contexts).toEqual([
      { frame: 0, phase: 'start' },
      { frame: 0, phase: 'draw' },
      { frame: 0, phase: 'raster', rasterLine: 7 },
    ]);
    expect(machine.call('dither', [0, 0, 1, 2, 8], { start: 0, end: 1 })).toBe(2);
  });

  it('exposes clamped pointer state and press transitions', () => {
    const machine = new DeterministicMachine(counterFactory, {
      seed: 9,
      workUnitsPerFrame: 100,
      updateRate: 60,
    });
    const input = {
      ...emptyInputFrame(),
      pointer: { x: 57, y: 91, primary: true, secondary: false, inside: true },
    };
    machine.runFrame(input);
    expect(machine.call('pointer_x', [], { start: 0, end: 1 })).toBe(57);
    expect(machine.call('pointer_y', [], { start: 0, end: 1 })).toBe(91);
    expect(machine.call('pointer_inside', [], { start: 0, end: 1 })).toBe(true);
    expect(machine.call('pointer_primary', [], { start: 0, end: 1 })).toBe(true);
    expect(machine.readInputByte(32)).toBe(57);
    expect(machine.readInputByte(34)).toBe(91);
    expect(machine.readInputByte(42)).toBe(5);
    const first = machine.snapshot();
    machine.runFrame(input);
    expect(machine.call('pointer_primary', [], { start: 0, end: 1 })).toBe(false);
    expect(machine.readInputByte(42)).toBe(0);
    machine.restore(first);
    expect(machine.readInputByte(42)).toBe(5);
    expect(machine.call('pointer_primary', [], { start: 0, end: 1 })).toBe(true);
    expect(() => {
      machine.runFrame({ ...input, pointer: { ...input.pointer, x: 240 } });
    }).toThrow(expect.objectContaining({ code: 'PX9008' }));
    expect(machine.snapshot()).toEqual(first);
  });
});
