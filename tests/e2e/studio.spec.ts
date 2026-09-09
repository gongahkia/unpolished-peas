import { readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';

import { expect, test, type Page } from '@playwright/test';

async function shellCommand(page: Page, command: string): Promise<void> {
  const input = page.getByLabel('PX-240C command');
  await expect(input).toBeEnabled();
  await input.fill(command);
  await input.press('Enter');
}

async function saveAndCloseTool(page: Page): Promise<void> {
  await page.locator('[data-common="save"]').click();
  await expect(page.locator('.tool-status')).toHaveText('SAVED');
  await page.locator('[data-common="back"]').click();
  await expect(page.locator('[data-view="shell"]')).toBeVisible();
}

test('complete local Studio and distribution workflow', async ({ page, context }, testInfo) => {
  const browserErrors: string[] = [];
  page.on('pageerror', (error) => browserErrors.push(error.message));
  page.on('console', (message) => {
    if (message.type() === 'error') browserErrors.push(message.text());
  });

  await page.goto('/');
  await expect(page.locator('html')).toHaveAttribute('data-studio-ready', 'true');
  await expect(page.locator('[data-view="shell"]')).toContainText('PXCL/1 READY');
  await expect
    .poll(() =>
      page.evaluate(async () => {
        await document.fonts.ready;
        return document.fonts.check('8px "PX-240C Bitmap"');
      }),
    )
    .toBe(true);

  await shellCommand(page, 'dir');
  await expect(page.locator('.terminal')).toContainText('cinder-circuit');
  await expect(page.locator('.terminal')).toContainText('ashvault');
  await expect(page.locator('.terminal')).toContainText('raster-rush');

  for (const cartridge of [
    { id: 'cinder-circuit', key: 'z', work: ['W03274', 'W03342'] },
    { id: 'ashvault', key: 'z', work: ['W12031'] },
    { id: 'raster-rush', key: 'Enter', work: ['W31682'] },
  ]) {
    await shellCommand(page, `load ${cartridge.id}`);
    await expect(page.locator('.active-cart')).toHaveText(cartridge.id.toUpperCase());
    await shellCommand(page, 'run');
    await expect(page.locator('[data-view="player"]')).toBeVisible();
    await expect(page.locator('.player-status')).toHaveText(/^F\d{5} W\d{5}$/);
    const keyCode = cartridge.key === 'Enter' ? 'Enter' : 'KeyZ';
    let activeStatus = '';
    for (let attempt = 0; attempt < 10; attempt += 1) {
      await page.evaluate(
        ({ key, code }) =>
          globalThis.dispatchEvent(new KeyboardEvent('keydown', { key, code, bubbles: true })),
        { key: cartridge.key, code: keyCode },
      );
      await page.waitForTimeout(200);
      activeStatus = await page.locator('.player-status').innerText();
      await page.evaluate(
        ({ key, code }) =>
          globalThis.dispatchEvent(new KeyboardEvent('keyup', { key, code, bubbles: true })),
        { key: cartridge.key, code: keyCode },
      );
      await page.waitForTimeout(100);
      if (cartridge.work.some((work) => activeStatus.includes(work))) break;
    }
    expect(cartridge.work.some((work) => activeStatus.includes(work))).toBe(true);
    await expect(page.locator('.player-status')).not.toHaveClass(/error/);
    await page.locator('.stop-player').click();
    await expect(page.locator('[data-view="shell"]')).toBeVisible();
  }

  await shellCommand(page, 'new e2e-bus MEMORY CONFORMANCE');
  await shellCommand(page, 'edit');
  await page
    .locator('textarea.source-input')
    .fill(await readFile('tests/conformance/memory.pxl', 'utf8'));
  await expect(page.locator('.diagnostic-strip')).toContainText('AUTOSAVED R');
  await page.locator('[data-action="back"]').click();
  await shellCommand(page, 'run');
  await expect
    .poll(async () => {
      const status = await page.locator('.player-status').innerText();
      return /^F\d{5} W\d{5}$/.test(status) ? Number(status.slice(1, 6)) : -1;
    })
    .toBeGreaterThanOrEqual(3);
  await page.locator('.stop-player').click();
  await shellCommand(page, 'debug');
  await page.locator('[data-debug="frame"]').click();
  await expect(page.locator('.debug-status')).toHaveText('PAUSED AT FRAME 1');
  await page.locator('[data-debug="rewind"]').click();
  await expect(page.locator('.debug-status')).toHaveText('REWOUND TO FRAME 0');
  await page.locator('[data-debug="frame"]').click();
  await expect(page.locator('.debug-status')).toHaveText('PAUSED AT FRAME 1');
  await page.locator('[data-debug="back"]').click();

  const visualCartridge = testInfo.outputPath('visual-conformance.pxc');
  execFileSync('target/debug/px240c', [
    'pack',
    'tests/conformance/visual',
    '--output',
    visualCartridge,
  ]);
  await shellCommand(page, 'import');
  await page.locator('input[type="file"]').setInputFiles(visualCartridge);
  await expect(page.locator('.terminal')).toContainText('IMPORTED visual-conformance');
  await shellCommand(page, 'run');
  await expect
    .poll(async () => {
      const status = await page.locator('.player-status').innerText();
      return /^F\d{5} W\d{5}$/.test(status) ? Number(status.slice(1, 6)) : -1;
    })
    .toBeGreaterThanOrEqual(3);
  await page.locator('.stop-player').click();

  await shellCommand(page, 'new e2e-input INPUT CONFORMANCE');
  await shellCommand(page, 'edit');
  await page
    .locator('textarea.source-input')
    .fill(await readFile('tests/conformance/input.pxl', 'utf8'));
  await expect(page.locator('.diagnostic-strip')).toContainText('AUTOSAVED R');
  await page.locator('[data-action="back"]').click();
  await shellCommand(page, 'run');
  await expect(page.locator('.player-status')).toHaveText(/^F\d{5} W\d{5}$/);
  await page.keyboard.down('z');
  await page.keyboard.down('f');
  await expect
    .poll(async () => {
      const status = await page.locator('.player-status').innerText();
      return /^F\d{5} W\d{5}$/.test(status) ? Number(status.slice(1, 6)) : -1;
    })
    .toBeGreaterThanOrEqual(3);
  await page.keyboard.up('z');
  await page.keyboard.up('f');
  await expect(page.locator('.player-status')).not.toHaveClass(/error/);
  await page.locator('.stop-player').click();

  await shellCommand(page, 'new e2e-system SYSTEM CONFORMANCE');
  await shellCommand(page, 'edit');
  await page
    .locator('textarea.source-input')
    .fill(await readFile('tests/conformance/system.pxl', 'utf8'));
  await expect(page.locator('.diagnostic-strip')).toContainText('AUTOSAVED R');
  await page.locator('[data-action="back"]').click();
  await shellCommand(page, 'run');
  await expect
    .poll(async () => {
      const status = await page.locator('.player-status').innerText();
      return /^F\d{5} W\d{5}$/.test(status) ? Number(status.slice(1, 6)) : -1;
    })
    .toBeGreaterThanOrEqual(3);
  await page.locator('.stop-player').click();
  await shellCommand(page, 'debug');
  await page.locator('[data-debug="frame"]').click();
  await expect(page.locator('.debug-status')).toHaveText('PAUSED AT FRAME 1');
  await page.locator('[data-debug="rewind"]').click();
  await expect(page.locator('.debug-status')).toHaveText('REWOUND TO FRAME 0');
  await page.locator('[data-debug="frame"]').click();
  await expect(page.locator('.debug-status')).toHaveText('PAUSED AT FRAME 1');
  await page.locator('[data-debug="back"]').click();

  await shellCommand(page, 'new e2e-alpha E2E ALPHA');
  await expect(page.locator('.active-cart')).toHaveText('E2E-ALPHA');
  await shellCommand(page, 'edit');
  const source = page.locator('textarea.source-input');
  await source.fill(`// Made by @gongahkia

state player_x: Int = 112

on update:
  if btn(pad1, right):
    player_x += 1

on draw:
  clear(1)
  rect_fill(player_x, 64, 16, 16, 23)
  print("E2E", 108, 88, 7)
`);
  await expect(page.locator('.diagnostic-strip')).toHaveText('OK / 0 ERRORS');
  await expect(page.locator('.diagnostic-strip')).toContainText('AUTOSAVED R');
  await page.locator('[data-action="back"]').click();
  await expect(page.locator('[data-view="shell"]')).toBeVisible();

  await shellCommand(page, 'run');
  await expect(page.locator('[data-view="player"]')).toBeVisible();
  await expect(page.locator('.player-status')).toHaveText(/^F\d{5} W\d{5}$/);
  await page.locator('.stop-player').click();
  await expect(page.locator('[data-view="shell"]')).toBeVisible();

  await shellCommand(page, 'debug');
  await expect(page.locator('[data-view="debugger"]')).toBeVisible();
  await page.locator('[data-debug="frame"]').click();
  await expect(page.locator('.debug-status')).toHaveText('PAUSED AT FRAME 1');
  await page.getByLabel('Watch expression').fill('player_x');
  await page.locator('[data-debug="watch"]').click();
  await expect(page.locator('.debug-status')).toHaveText('WATCHING player_x');
  await expect(page.locator('.debug-output')).toContainText('? player_x = 112');
  await page.locator('[data-debug="rewind"]').click();
  await expect(page.locator('.debug-status')).toHaveText('REWOUND TO FRAME 0');
  await page.locator('[data-debug="back"]').click();
  await expect(page.locator('[data-view="shell"]')).toBeVisible();

  await shellCommand(page, 'project');
  await page.locator('[name="title"]').fill('E2E TOOL CART');
  await page.locator('[name="update"]').selectOption('30');
  await saveAndCloseTool(page);

  await shellCommand(page, 'sprite');
  await page.locator('.pixel-canvas').click({ position: { x: 46, y: 46 } });
  await page.locator('[data-act="add"]').click();
  await expect(page.locator('.frame-readout')).toHaveText('2/2');
  await page.locator('[data-act="undo"]').click();
  await expect(page.locator('.frame-readout')).toHaveText('1/1');
  await saveAndCloseTool(page);

  await shellCommand(page, 'map');
  await page.locator('.map-canvas').click({ position: { x: 30, y: 30 } });
  await page.locator('[data-map="add"]').click();
  await expect(page.locator('.layer-readout')).toHaveText('2/2');
  await page.locator('[data-map="undo"]').click();
  await expect(page.locator('.layer-readout')).toHaveText('1/1');
  await saveAndCloseTool(page);

  await shellCommand(page, 'palette');
  await page.locator('.raster-line').fill('80');
  await expect(page.locator('.raster-readout')).toContainText('LINE 80');
  await saveAndCloseTool(page);

  await shellCommand(page, 'sfx');
  await page.locator('[name="wave"]').selectOption('triangle');
  await page.locator('[name="pan"]').fill('0.4');
  await saveAndCloseTool(page);

  await shellCommand(page, 'music');
  await page.locator('[role="gridcell"]').first().click();
  await expect(page.locator('[role="gridcell"]').first()).toHaveText('30');
  await page.locator('[data-add-pattern]').click();
  await expect(page.locator('.pattern-select')).toHaveValue('01');
  await page.locator('[data-track-undo]').click();
  await expect(page.locator('.pattern-select')).toHaveValue('00');
  await saveAndCloseTool(page);

  await shellCommand(page, 'manual');
  await page.getByLabel('Search manual').fill('pointer');
  await expect(page.locator('.manual-page')).toContainText('pointer_x/y');
  await page.locator('[data-back]').click();
  await shellCommand(page, 'explore');
  await page.getByRole('button', { name: 'IR', exact: true }).click();
  await expect(page.locator('.explorer-output')).toContainText('routines');
  await page.locator('[data-back]').click();

  await shellCommand(page, 'recover');
  await expect(page.locator('.terminal')).toContainText(/R\d+ E2E/);

  const packedDownloadPromise = page.waitForEvent('download');
  await shellCommand(page, 'pack');
  const packedDownload = await packedDownloadPromise;
  const packedPath = await packedDownload.path();
  expect(packedPath).not.toBeNull();
  await expect(page.locator('.terminal')).toContainText(/PACKED e2e-alpha\.pxc \d+ BYTES/);

  await shellCommand(page, 'import');
  await page.locator('input[type="file"]').setInputFiles(packedPath);
  await expect(page.locator('[data-view="shell"]')).toBeVisible();
  await expect(page.locator('.terminal')).toContainText('IMPORTED e2e-alpha');

  const htmlDownloadPromise = page.waitForEvent('download');
  await shellCommand(page, 'export');
  const htmlDownload = await htmlDownloadPromise;
  const htmlPath = await htmlDownload.path();
  expect(htmlPath).not.toBeNull();
  await expect(page.locator('.terminal')).toContainText(/EXPORTED e2e-alpha\.html \d+ BYTES/);

  const standalone = await context.newPage();
  const standaloneErrors: string[] = [];
  standalone.on('pageerror', (error) => standaloneErrors.push(error.message));
  standalone.on('console', (message) => {
    if (message.type() === 'error') standaloneErrors.push(message.text());
  });
  await standalone.goto('/');
  await standalone.setContent(await readFile(htmlPath, 'utf8'));
  await expect(standalone.locator('#status')).toHaveText(/^F\d{5} W\d{5}$/);
  await standalone.locator('#source').click();
  await expect(standalone.locator('#inspector')).toBeVisible();
  await expect(standalone.locator('#source-view')).toContainText('Made by @gongahkia');
  expect(standaloneErrors).toEqual([]);
  await standalone.close();

  await page.evaluate(async () => navigator.serviceWorker.ready);
  await page.reload();
  await expect
    .poll(() => page.evaluate(() => navigator.serviceWorker.controller !== null))
    .toBe(true);
  await context.setOffline(true);
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-studio-ready', 'true');
  await expect(page.locator('[data-view="shell"]')).toContainText('PXCL/1 READY');
  await context.setOffline(false);

  expect(browserErrors).toEqual([]);
});
