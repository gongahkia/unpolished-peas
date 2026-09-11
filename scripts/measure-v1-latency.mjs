/* global console, process, performance */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

import { firefox } from '@playwright/test';

const baseURL = process.env.PX240C_BENCHMARK_URL ?? 'http://127.0.0.1:4173';
const output = process.env.PX240C_BENCHMARK_OUTPUT ?? 'output/v1-latency.json';
const temporary = await mkdtemp(join(tmpdir(), 'px240c-v1-latency-'));
const cartridge = join(temporary, 'api-tour.pxc');
execFileSync('target/debug/px240c', ['pack', 'examples/api-tour', '--output', cartridge]);

const browser = await firefox.launch();
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await context.newPage();
  page.setDefaultTimeout(30_000);
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  page.on('console', (message) => {
    if (message.type() === 'error') errors.push(message.text());
  });
  const command = async (text) => {
    const input = page.getByLabel('PX-240C command');
    await input.fill(text);
    await input.press('Enter');
  };

  await page.goto(baseURL);
  await page.locator('html[data-studio-ready="true"]').waitFor();
  await command('import');
  await page.locator('input[type="file"]').setInputFiles(cartridge);
  await page.locator('.terminal').filter({ hasText: 'IMPORTED api-tour' }).waitFor();

  const samples = [];
  for (let index = 0; index < 11; index += 1) {
    await command('edit');
    const source = page.locator('textarea.source-input');
    const original = await source.inputValue();
    const started = performance.now();
    await source.fill(`${original}\n// V1 latency sample ${String(index)}\n`);
    await page.locator('[data-action="back"]').click();
    await command('run');
    await page
      .locator('.player-status')
      .filter({ hasText: /^F\d{5} W\d{5}$/ })
      .waitFor();
    samples.push(performance.now() - started);
    await page.locator('.stop-player').click();
  }

  assert.deepEqual(errors, []);
  const warm = samples.slice(1);
  const sorted = [...warm].sort((left, right) => left - right);
  const result = {
    revision: 1,
    browser: `Firefox ${browser.version()}`,
    project: 'examples/api-tour (two source modules)',
    description:
      'Playwright wall clock from source fill through revision-safe save, deterministic restart, compile, inline Worker boot and first rendered frame',
    coldMilliseconds: samples[0],
    warmMilliseconds: warm,
    medianMilliseconds: (sorted[4] + sorted[5]) / 2,
  };
  await mkdir(dirname(output), { recursive: true });
  await writeFile(output, `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify(result, null, 2));
  await context.close();
} finally {
  await browser.close();
  await rm(temporary, { recursive: true });
}
