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
    for (const updateRate of [30, 60] as const) {
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
