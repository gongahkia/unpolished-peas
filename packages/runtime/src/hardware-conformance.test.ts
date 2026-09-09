import { execFileSync } from 'node:child_process';
import { deepStrictEqual } from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createConsoleRuntime } from './console-runtime';
import { MEMORY } from './bus';
import { BUTTONS, emptyInputFrame } from './input';
import type { CartridgeFactory } from './machine';
import type { ProjectAssetDeclaration } from './asset-codec';

describe('public PXCL hardware conformance', () => {
  const root = fileURLToPath(new URL('../../../', import.meta.url));
  let temporary: string;
  beforeAll(() => {
    temporary = mkdtempSync(join(tmpdir(), 'px240c-conformance-'));
    execFileSync('cargo', ['build', '--quiet', '--package', 'px240c-cli'], { cwd: root });
  }, 120_000);
  afterAll(() => {
    if (temporary) rmSync(temporary, { recursive: true, force: true });
  });

  for (const mode of ['release', 'debug']) {
    it(`runs runtime-call globals inside the boot boundary in ${mode}`, async () => {
      const source = join(root, 'tests/conformance/boot.pxl');
      const output = join(temporary, `boot-${mode}.mjs`);
      execFileSync(join(root, 'target/debug/px240c'), [
        'build',
        source,
        '--output',
        output,
        ...(mode === 'debug' ? ['--debug'] : []),
      ]);
      const generated = (await import(/* @vite-ignore */ pathToFileURL(output).href)) as {
        default: CartridgeFactory;
      };
      const runtime = createConsoleRuntime(generated.default, {
        seed: 1,
        updateRate: 60,
        workUnitsPerFrame: 50_000,
        debug: mode === 'debug',
      });
      const boot = runtime.snapshot();
      expect([...boot.graphics.front.slice(0, 3)]).toEqual([0, 11, 23]);
      const callback = readFileSync(source, 'utf8').indexOf('on start:');
      expect(
        boot.machine.budget.attribution.some(
          (entry) => entry.sourceSpan.start < callback && entry.units > 0,
        ),
      ).toBe(true);
      const bootLimit = boot.machine.budget.used;
      const exact = createConsoleRuntime(generated.default, {
        seed: 1,
        updateRate: 60,
        workUnitsPerFrame: bootLimit,
        debug: mode === 'debug',
      });
      expect(exact.snapshot().machine.budget.used).toBe(bootLimit);
      const finalCall = 'pixel(2, 0, 23)';
      const finalStart = readFileSync(source, 'utf8').indexOf(finalCall);
      expect(() =>
        createConsoleRuntime(generated.default, {
          seed: 1,
          updateRate: 60,
          workUnitsPerFrame: bootLimit - 1,
          debug: mode === 'debug',
        }),
      ).toThrow(
        expect.objectContaining({
          code: 'PX9001',
          sourceSpan: { start: finalStart, end: finalStart + finalCall.length },
        }),
      );
      expect(boot.memory.regions[0]?.bytes[0]).toBe(7);
      const first = runtime.runFrame(emptyInputFrame());
      expect(runtime.snapshot().memory.regions[0]?.bytes[0]).toBe(8);
      runtime.runFrame(emptyInputFrame());
      expect(runtime.snapshot().memory.regions[0]?.bytes[0]).toBe(9);
      runtime.restore(boot);
      deepStrictEqual(runtime.runFrame(emptyInputFrame()), first);
    });

    it(`runs mixed audio controls and retains exact PCM on replay in ${mode}`, async () => {
      const cli = join(root, 'target/debug/px240c');
      const project = join(root, 'tests/conformance/audio');
      const output = join(temporary, `audio-${mode}.mjs`);
      execFileSync(cli, [
        'build',
        project,
        '--output',
        output,
        ...(mode === 'debug' ? ['--debug'] : []),
      ]);
      const manifest = JSON.parse(execFileSync(cli, ['info', project], { encoding: 'utf8' })) as {
        assets: Record<string, ProjectAssetDeclaration>;
      };
      const generated = (await import(/* @vite-ignore */ pathToFileURL(output).href)) as {
        default: CartridgeFactory;
      };
      const runtime = createConsoleRuntime(generated.default, {
        seed: 1,
        updateRate: 60,
        workUnitsPerFrame: 50_000,
        debug: mode === 'debug',
        assets: {
          declarations: manifest.assets,
          files: Object.fromEntries(
            Object.values(manifest.assets).map((asset) => [
              asset.path,
              new Uint8Array(readFileSync(join(project, asset.path))),
            ]),
          ),
        },
      });
      for (let frame = 0; frame < 4; frame += 1) {
        const before = runtime.snapshot();
        const report = runtime.runFrame(emptyInputFrame());
        const after = runtime.snapshot();
        expect(report.output.audio.left.some((sample) => sample !== 0)).toBe(frame % 2 === 1);
        expect(report.output.audio.right.some((sample) => sample !== 0)).toBe(frame % 2 === 1);
        expect(
          after.audio.voices.every(
            (voice) => voice.active && voice.ageFrames === 1 && voice.volumeScale === frame % 2,
          ),
        ).toBe(true);
        const ram = after.memory.regions.find((region) => region.address === MEMORY.ram)?.bytes;
        if (ram === undefined) throw new Error('missing audio capture');
        const view = new DataView(ram.buffer, ram.byteOffset, ram.byteLength);
        expect(view.getBigUint64(0, true)).toBe(BigInt(frame));
        expect(view.getBigUint64(8, true)).toBe(BigInt(17 + frame * 8));
        for (let slot = 0; slot < 8; slot += 1) {
          expect(view.getFloat64(32 + slot * 64 + 16, true)).toBe(frame % 2);
          expect(view.getBigUint64(32 + slot * 64 + 48, true)).toBe(BigInt(9 + frame * 8 + slot));
        }
        runtime.restore(before);
        deepStrictEqual(runtime.runFrame(emptyInputFrame()), report);
        deepStrictEqual(runtime.snapshot(), after);
      }
      const current = runtime.snapshot();
      const state = current.machine.cartridge.state as Record<string, unknown>;
      const counters = Object.entries(state).filter(([, value]) => value === 4);
      expect(counters).toHaveLength(1);
      const counter = counters[0]?.[0];
      if (counter === undefined) throw new Error('missing audio fixture frame counter');
      runtime.restore({
        ...current,
        machine: {
          ...current.machine,
          frame: 65_535,
          execution: { ...current.machine.execution, updates: 65_535 },
          cartridge: { ...current.machine.cartridge, state: { ...state, [counter]: 65_535 } },
        },
        audio: { ...current.audio, frame: 65_535 },
      });
      for (const frame of [65_535, 65_536]) {
        const before = runtime.snapshot();
        const report = runtime.runFrame(emptyInputFrame());
        expect(report.frame).toBe(frame);
        expect(report.output.audio.left.some((sample) => sample !== 0)).toBe(frame % 2 === 1);
        const after = runtime.snapshot();
        const ram = after.memory.regions.find((region) => region.address === MEMORY.ram)?.bytes;
        if (ram === undefined) throw new Error('missing audio counter capture');
        expect(new DataView(ram.buffer, ram.byteOffset, ram.byteLength).getBigUint64(0, true)).toBe(
          BigInt(frame),
        );
        runtime.restore(before);
        deepStrictEqual(runtime.runFrame(emptyInputFrame()), report);
        deepStrictEqual(runtime.snapshot(), after);
      }
    });

    for (const updateRate of [30, 60] as const) {
      it(`runs system conformance in ${mode} at ${String(updateRate)} Hz`, async () => {
        const output = join(temporary, `system-${mode}-${String(updateRate)}.mjs`);
        execFileSync(join(root, 'target/debug/px240c'), [
          'build',
          join(root, 'tests/conformance/system.pxl'),
          '--output',
          output,
          ...(mode === 'debug' ? ['--debug'] : []),
        ]);
        const generated = (await import(/* @vite-ignore */ pathToFileURL(output).href)) as {
          default: CartridgeFactory;
        };
        const runtime = createConsoleRuntime(generated.default, {
          seed: 1,
          updateRate,
          workUnitsPerFrame: 50_000,
          debug: mode === 'debug',
        });
        for (let frame = 0; frame < 4; frame += 1) {
          const before = runtime.snapshot();
          const report = runtime.runFrame(emptyInputFrame());
          const after = runtime.snapshot();
          const ram = after.memory.regions.find((region) => region.address === MEMORY.ram)?.bytes;
          if (ram === undefined) throw new Error('missing system capture');
          const view = new DataView(ram.buffer, ram.byteOffset, ram.byteLength);
          expect(view.getBigUint64(0, true)).toBe(BigInt(frame));
          expect(view.getBigUint64(8, true)).toBe(
            BigInt(updateRate === 60 ? frame + 1 : Math.floor(frame / 2) + 1),
          );
          expect(view.getFloat64(16, true)).toBe(frame / 60);
          expect(view.getUint32(24, true)).toBe(after.machine.rngState);
          expect(view.getUint8(28)).toBe(updateRate);
          expect(view.getUint8(29)).toBe(3);
          expect(view.getUint16(30, true)).toBe(65535);
          expect(view.getBigUint64(32, true)).toBeGreaterThan(0n);
          expect(view.getBigUint64(32, true)).toBeLessThan(BigInt(report.workUnits));
          expect(view.getBigUint64(40, true)).toBe(50_000n);
          expect(view.getUint8(48)).toBe(3);
          expect(view.getBigUint64(64, true)).toBe(0n);
          expect(view.getUint32(88, true)).toBe(1);
          expect(view.getUint8(93)).toBe(1);
          expect(view.getUint8(112)).toBe(2);
          runtime.restore(before);
          deepStrictEqual(runtime.runFrame(emptyInputFrame()), report);
          deepStrictEqual(runtime.snapshot(), after);
        }
      });

      it(`runs all-port input conformance in ${mode} at ${String(updateRate)} Hz`, async () => {
        const output = join(temporary, `input-${mode}-${String(updateRate)}.mjs`);
        execFileSync(join(root, 'target/debug/px240c'), [
          'build',
          join(root, 'tests/conformance/input.pxl'),
          '--output',
          output,
          ...(mode === 'debug' ? ['--debug'] : []),
        ]);
        const generated = (await import(/* @vite-ignore */ pathToFileURL(output).href)) as {
          default: CartridgeFactory;
        };
        const runtime = createConsoleRuntime(generated.default, {
          seed: 1,
          updateRate,
          workUnitsPerFrame: 50_000,
          debug: mode === 'debug',
        });
        const mask = (frame: number, port: number): number =>
          frame < 0 || frame % 3 === 2 ? 0 : 1 << ((Math.floor(frame / 3) + port * 3) % 12);
        for (let frame = 0; frame < 36; frame += 1) {
          const input = emptyInputFrame();
          for (const [port, controller] of input.controllers.entries())
            for (const [bit, button] of BUTTONS.entries())
              Object.assign(controller.buttons, {
                [button]: (mask(frame, port) & (1 << bit)) !== 0,
              });
          const trace = {
            ...input,
            pointer: {
              x: frame * 6,
              y: frame * 4,
              primary: frame % 3 === 0,
              secondary: frame % 3 === 1,
              inside: frame % 3 !== 2,
            },
          };
          const before = runtime.snapshot();
          const report = runtime.runFrame(trace);
          const after = runtime.snapshot();
          const ram = after.memory.regions.find((region) => region.address === MEMORY.ram)?.bytes;
          if (ram === undefined) throw new Error('missing input capture');
          const view = new DataView(ram.buffer, ram.byteOffset, ram.byteLength);
          for (let port = 0; port < 4; port += 1) {
            const current = mask(frame, port);
            const previous = mask(frame - 1, port);
            expect(
              Array.from({ length: 4 }, (_, field) => view.getUint16(port * 8 + field * 2, true)),
            ).toEqual([current, previous, current & ~previous, previous & ~current]);
          }
          expect(view.getUint16(32, true)).toBe(trace.pointer.x);
          expect(view.getUint16(34, true)).toBe(trace.pointer.y);
          if (frame === 1 || frame === 12) {
            runtime.restore(before);
            deepStrictEqual(runtime.runFrame(trace), report);
            deepStrictEqual(runtime.snapshot(), after);
          }
        }
      });
    }

    it(`compiles and runs visual allocation conformance in ${mode} with full replay`, async () => {
      const cli = join(root, 'target/debug/px240c');
      const project = join(root, 'tests/conformance/visual');
      const output = join(temporary, `visual-${mode}.mjs`);
      execFileSync(cli, [
        'build',
        project,
        '--output',
        output,
        ...(mode === 'debug' ? ['--debug'] : []),
      ]);
      const manifest = JSON.parse(execFileSync(cli, ['info', project], { encoding: 'utf8' })) as {
        assets: Record<string, ProjectAssetDeclaration>;
      };
      const generated = (await import(/* @vite-ignore */ pathToFileURL(output).href)) as {
        default: CartridgeFactory;
      };
      const runtime = createConsoleRuntime(generated.default, {
        seed: 1,
        updateRate: 60,
        workUnitsPerFrame: 50_000,
        debug: mode === 'debug',
        assets: {
          declarations: manifest.assets,
          files: Object.fromEntries(
            Object.values(manifest.assets).map((asset) => [
              asset.path,
              new Uint8Array(readFileSync(join(project, asset.path))),
            ]),
          ),
        },
      });
      const boot = runtime.snapshot();
      const first = runtime.runFrame(emptyInputFrame());
      expect([...first.output.indexedPixels.slice(0, 3)]).toEqual([23, 11, 9]);
      const after = runtime.snapshot();
      runtime.runFrame(emptyInputFrame());
      runtime.restore(boot);
      deepStrictEqual(runtime.runFrame(emptyInputFrame()), first);
      deepStrictEqual(runtime.snapshot(), after);
    });

    it(`compiles and runs memory conformance in ${mode} with full replay`, async () => {
      const output = join(temporary, `memory-${mode}.mjs`);
      execFileSync(join(root, 'target/debug/px240c'), [
        'build',
        join(root, 'tests/conformance/memory.pxl'),
        '--output',
        output,
        ...(mode === 'debug' ? ['--debug'] : []),
      ]);
      const generated = (await import(/* @vite-ignore */ pathToFileURL(output).href)) as {
        default: CartridgeFactory;
      };
      const runtime = createConsoleRuntime(generated.default, {
        seed: 1,
        updateRate: 60,
        workUnitsPerFrame: 50_000,
        debug: mode === 'debug',
      });
      const boot = runtime.snapshot();
      expect(boot.graphics.front[3]).toBe(7);
      expect(boot.graphics.front[4]).toBe(23);
      const first = runtime.runFrame(emptyInputFrame());
      expect([...first.output.indexedPixels.slice(0, 5)]).toEqual([7, 11, 0, 7, 11]);
      expect(
        runtime.snapshot().memory.regions.find((region) => region.address === MEMORY.ram)
          ?.bytes[100],
      ).toBe(1);
      const after = runtime.snapshot();
      runtime.runFrame(emptyInputFrame());
      runtime.restore(boot);
      deepStrictEqual(runtime.runFrame(emptyInputFrame()), first);
      deepStrictEqual(runtime.snapshot(), after);
    });
  }
});
