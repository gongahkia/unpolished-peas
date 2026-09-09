import { execFileSync } from 'node:child_process';
import { deepStrictEqual } from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createConsoleRuntime } from './console-runtime';
import { MEMORY } from './bus';
import { emptyInputFrame } from './input';
import type { CartridgeFactory } from './machine';

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
