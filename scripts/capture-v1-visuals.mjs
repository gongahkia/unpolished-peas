/* global console, process */
import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';

import { chromium, firefox } from '@playwright/test';

const baseURL = process.env.PX240C_VISUAL_URL ?? 'http://127.0.0.1:4173';
const output = 'output/playwright';
await mkdir(output, { recursive: true });

for (const [name, engine] of [
  ['firefox', firefox],
  ['chromium', chromium],
]) {
  const browser = await engine.launch();
  try {
    const context = await browser.newContext({ viewport: { width: 1180, height: 760 } });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    page.on('console', (message) => {
      if (message.type() === 'error') errors.push(message.text());
    });
    await page.goto(baseURL);
    await page.locator('html[data-studio-ready="true"]').waitFor();
    await page.screenshot({ path: `${output}/v1-${name}-shell.png` });

    const command = page.getByLabel('PX-240C command');
    await command.fill('load signal-4k');
    await command.press('Enter');
    await command.fill('run');
    await command.press('Enter');
    await page
      .locator('.player-status')
      .filter({ hasText: /^F\d{5} W\d{5}$/ })
      .waitFor();
    await page.waitForTimeout(500);
    await page.screenshot({ path: `${output}/v1-${name}-scaled.png` });

    await page.locator('.capture-scale').selectOption('1');
    const download = page.waitForEvent('download');
    await page.locator('.capture-shot').click();
    const native = await download;
    const nativePath = await native.path();
    assert.notEqual(nativePath, null);
    await writeFile(`${output}/v1-${name}-native.png`, await readFile(nativePath));
    assert.deepEqual(errors, []);
    console.log(`${name} ${browser.version()}: visual captures complete`);
    await context.close();
  } finally {
    await browser.close();
  }
}
