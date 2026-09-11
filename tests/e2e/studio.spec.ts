import { mkdir, readFile, writeFile } from 'node:fs/promises';
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
  await expect(page.locator('.terminal')).toContainText('px240c-service');
  await expect(page.locator('.terminal')).toContainText('signal-4k');
  await expect(page.locator('.terminal')).toContainText('pocket-relay');
  await expect(page.locator('.terminal')).toContainText('hardware-gauntlet');

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

  await shellCommand(page, 'load px240c-service');
  await shellCommand(page, 'run');
  await expect(page.locator('[data-view="player"]')).toBeVisible();
  await expect
    .poll(async () => {
      const status = await page.locator('.player-status').innerText();
      return /^F\d{5} W\d{5}$/.test(status) ? Number(status.slice(1, 6)) : -1;
    })
    .toBeGreaterThanOrEqual(3);
  await expect(page.locator('.player-status')).not.toHaveClass(/error/);
  await page.locator('.stop-player').click();

  for (const id of ['signal-4k', 'pocket-relay', 'hardware-gauntlet']) {
    await shellCommand(page, `load ${id}`);
    await shellCommand(page, 'run');
    await expect
      .poll(async () => {
        const status = await page.locator('.player-status').innerText();
        return /^F\d{5} W\d{5}$/.test(status) ? Number(status.slice(1, 6)) : -1;
      })
      .toBeGreaterThanOrEqual(2);
    await expect(page.locator('.player-status')).not.toHaveClass(/error/);
    await page.locator('.stop-player').click();
  }
  await shellCommand(page, 'load signal-4k');
  await shellCommand(page, 'debug');
  await page.locator('[data-debug="in"]').click();
  await expect(page.locator('.debug-status')).toContainText('main.pxl');
  await page.locator('[data-debug="back"]').click();

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
  await page.locator('.debug-tabs button').filter({ hasText: 'MEMO' }).click();
  await expect(page.locator('.memory-debug-entry')).toBeVisible();
  await page.getByLabel('Memory address').fill('000064');
  await page.getByLabel('Memory length').fill('8');
  await page.locator('[data-debug="memory-read"]').click();
  await expect(page.locator('.debug-output')).toContainText('RAM RW / HEX');
  await expect(page.locator('.debug-output')).toContainText('000064');
  await page.getByLabel('Memory number format').selectOption('10');
  await page.locator('[data-debug="memory-read"]').click();
  await expect(page.locator('.debug-output')).toContainText('/ DEC');
  await page.getByLabel('Memory byte value').fill('9');
  await page.locator('[data-debug="memory-write"]').click();
  await expect(page.locator('.debug-status')).toHaveText('SET 000064=09 / PAUSED');
  await page.locator('[data-debug="memory-watch"]').click();
  await expect(page.locator('.debug-status')).toHaveText('WATCHING 000064');
  await page.locator('[data-debug="frame"]').click();
  await expect(page.locator('.debug-status')).toHaveText(/WATCH 000064 09>02/);
  await page.locator('[data-debug="memory-manual"]').click();
  await expect(page.locator('[data-view="manual"]')).toBeVisible();
  await expect(page.locator('.manual-page')).toContainText('Hardware Revision 1');
  await page.locator('[data-back]').click();

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

  const audioCartridge = testInfo.outputPath('audio-conformance.pxc');
  execFileSync('target/debug/px240c', [
    'pack',
    'tests/conformance/audio',
    '--output',
    audioCartridge,
  ]);
  await shellCommand(page, 'import');
  await page.locator('input[type="file"]').setInputFiles(audioCartridge);
  await expect(page.locator('.terminal')).toContainText('IMPORTED audio-conformance');
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

  await shellCommand(page, 'new e2e-boot BOOT CONFORMANCE');
  await shellCommand(page, 'edit');
  await page
    .locator('textarea.source-input')
    .fill(await readFile('tests/conformance/boot.pxl', 'utf8'));
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

  await shellCommand(page, 'new e2e-save SAVE CONFORMANCE');
  await shellCommand(page, 'edit');
  await page.locator('textarea.source-input').fill(`on start:
  save_set_int("score", 7)

on draw:
  clear(0)
`);
  await expect(page.locator('.diagnostic-strip')).toContainText('AUTOSAVED R');
  await page.locator('[data-action="back"]').click();
  await shellCommand(page, 'run');
  await expect
    .poll(async () => {
      const status = await page.locator('.player-status').innerText();
      return /^F\d{5} W\d{5}$/.test(status) ? Number(status.slice(1, 6)) : -1;
    })
    .toBeGreaterThanOrEqual(1);
  await page.locator('.stop-player').click();
  await shellCommand(page, 'edit');
  await page
    .locator('textarea.source-input')
    .fill(await readFile('tests/conformance/save.pxl', 'utf8'));
  await expect(page.locator('.diagnostic-strip')).toContainText('AUTOSAVED R');
  await page.locator('[data-action="back"]').click();
  await shellCommand(page, 'run');
  await expect
    .poll(async () => {
      const status = await page.locator('.player-status').innerText();
      return /^F\d{5} W\d{5}$/.test(status) ? Number(status.slice(1, 6)) : -1;
    })
    .toBeGreaterThanOrEqual(2);
  await expect(page.locator('.player-status')).not.toHaveClass(/error/);
  await page.locator('.stop-player').click();

  await shellCommand(page, 'new e2e-link TINY LINK');
  await shellCommand(page, 'share');
  await expect(page.locator('[data-view="share"]')).toBeVisible();
  await expect(page.locator('[data-view="share"]')).toContainText('FRAGMENT ONLY / NO UPLOAD');
  const shareUrl = await page.getByLabel('Cartridge share URL').inputValue();
  expect(shareUrl).toContain('#pxc=');
  expect(shareUrl.length).toBeLessThanOrEqual(8_256);
  const fragmentRequests: string[] = [];
  const fragmentPage = await context.newPage();
  fragmentPage.on('request', (request) => fragmentRequests.push(request.url()));
  await fragmentPage.goto(shareUrl);
  await expect(fragmentPage.locator('html')).toHaveAttribute('data-studio-ready', 'true');
  await expect(fragmentPage.locator('.terminal')).toContainText('FRAGMENT IMPORT e2e-link');
  expect(fragmentRequests.every((url) => !url.includes('pxc='))).toBe(true);
  await fragmentPage.close();
  await page.locator('[data-back]').click();

  await shellCommand(page, 'shelf');
  await expect(page.locator('[data-view="shelf"]')).toContainText('PX-240C CART BAY');
  await page.locator('.shelf-item[data-id="e2e-link"]').click();
  await page.locator('[data-shelf="play"]').click();
  await expect(page.locator('.player-status')).toHaveText(/^F\d{5} W\d{5}$/);
  await page.locator('.stop-player').click();
  await shellCommand(page, 'shelf');
  await page.locator('.shelf-item[data-id="e2e-link"]').click();
  await page.locator('[data-shelf="source"]').click();
  await page.getByRole('button', { name: 'main.pxl' }).click();
  await expect(page.locator('[data-view="inspector"]')).toContainText('Made by @gongahkia');
  await page.locator('[data-back]').click();
  await shellCommand(page, 'shelf');
  await page.locator('.shelf-item[data-id="e2e-link"]').click();
  await page.locator('[data-shelf="favorite"]').click();
  await expect(page.locator('.shelf-item[data-id="e2e-link"] strong')).toContainText('★');
  await page.locator('.shelf-item[data-id="e2e-link"]').click();
  await page.locator('[data-shelf="copy"]').click();
  await expect(page.locator('.shelf-item[data-id="e2e-link.copy"]')).toBeVisible();
  await page.locator('.shelf-item[data-id="e2e-link.copy"]').click();
  await page.locator('[data-shelf="rename"]').click();
  await page.getByRole('textbox', { name: 'TITLE' }).fill('LINK ARCHIVE COPY');
  await page.getByRole('button', { name: 'SAVE NAME' }).click();
  await expect(page.locator('.shelf-item[data-id="e2e-link.copy"] strong')).toContainText(
    'LINK ARCHIVE COPY',
  );
  await page.locator('.shelf-item[data-id="e2e-link.copy"]').click();
  const shelfExportPromise = page.waitForEvent('download');
  await page.locator('[data-shelf="export"]').click();
  expect((await shelfExportPromise).suggestedFilename()).toBe('e2e-link.copy.pxc');
  await page.locator('.shelf-item[data-id="e2e-link.copy"]').click();
  await page.locator('[data-shelf="remove"]').click();
  await expect(page.locator('.shelf-status')).toContainText('CONFIRM REMOVE');
  await page.locator('[data-shelf="remove"]').click();
  const removedCopy = page.locator('.shelf-item.removed[data-id="e2e-link.copy"]');
  await expect(removedCopy).toBeVisible();
  await removedCopy.click();
  await expect(page.locator('[data-shelf="remove"]')).toHaveText('RESTORE');
  await page.locator('[data-shelf="remove"]').click();
  await expect(page.locator('.shelf-item[data-id="e2e-link.copy"]')).not.toHaveClass(/removed/);
  await page.locator('[data-shelf="back"]').click();

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
  await page.locator('.capture-scale').selectOption('2');
  const screenshotPromise = page.waitForEvent('download');
  await page.locator('.capture-shot').click();
  const screenshot = await screenshotPromise;
  const screenshotPath = await screenshot.path();
  expect(screenshotPath).not.toBeNull();
  const screenshotBytes = await readFile(screenshotPath);
  expect(screenshotBytes.subarray(0, 8)).toEqual(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  expect(screenshotBytes.readUInt32BE(16)).toBe(480);
  expect(screenshotBytes.readUInt32BE(20)).toBe(288);

  const gifPromise = page.waitForEvent('download');
  await page.locator('.capture-gif').click();
  const gif = await gifPromise;
  const gifPath = await gif.path();
  expect(gifPath).not.toBeNull();
  const gifBytes = await readFile(gifPath);
  expect(gifBytes.subarray(0, 6).toString('ascii')).toBe('GIF89a');
  expect(gifBytes.readUInt16LE(6)).toBe(240);
  expect(gifBytes.readUInt16LE(8)).toBe(144);
  expect(gifBytes.at(-1)).toBe(0x3b);
  expect(
    await page.evaluate(async (data) => {
      const image = new Image();
      const loaded = new Promise<[number, number]>((resolve, reject) => {
        image.addEventListener('load', () => {
          resolve([image.naturalWidth, image.naturalHeight]);
        });
        image.addEventListener('error', () => {
          reject(new Error('GIF did not decode'));
        });
      });
      image.src = `data:image/gif;base64,${data}`;
      return await loaded;
    }, gifBytes.toString('base64')),
  ).toEqual([240, 144]);

  const replayPromise = page.waitForEvent('download');
  await page.locator('.capture-replay').click();
  const replay = await replayPromise;
  const replayPath = await replay.path();
  expect(replayPath).not.toBeNull();
  const replayJson = JSON.parse(await readFile(replayPath, 'utf8')) as {
    revision: number;
    frames: unknown[];
  };
  expect(replayJson.revision).toBe(1);
  expect(replayJson.frames.length).toBeGreaterThan(0);
  await page.locator('.replay-input').setInputFiles(replayPath);
  await expect(page.locator('[data-view="player"]')).toHaveAttribute('data-replay', 'true');
  await expect(page.locator('.player-status')).toHaveText(/^F\d{5} W\d{5}$/);
  await page.locator('.stop-player').click();
  await expect(page.locator('[data-view="shell"]')).toBeVisible();

  await shellCommand(page, 'debug');
  await expect(page.locator('[data-view="debugger"]')).toBeVisible();
  await page.locator('[data-debug="in"]').click();
  await expect(page.locator('.debug-status')).toHaveText('PAUSED main.pxl:3 / DEPTH 0');
  await expect(page.locator('.debug-location')).toContainText('F0000 main.pxl:L3');
  await expect(page.locator('.debug-output')).toContainText('state player_x: Int = 112');
  await page.locator('[data-debug="in"]').click();
  await expect(page.locator('.debug-status')).toHaveText('BOOT COMPLETE');
  await page.locator('[data-debug="in"]').click();
  await expect(page.locator('.debug-status')).toHaveText('PAUSED main.pxl:6 / DEPTH 1');
  await expect(page.locator('.debug-location')).toContainText('F0000 main.pxl:L6');
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
  await page.locator('[name="players"]').fill('2');
  await page.locator('[name="controls"]').fill('PAD + POINTER');
  await saveAndCloseTool(page);

  await shellCommand(page, 'sprite');
  await page.locator('.pixel-canvas').click({ position: { x: 46, y: 46 } });
  await page.locator('[data-act="add"]').click();
  await expect(page.locator('.frame-readout')).toHaveText('2/2');
  await page.locator('[data-act="undo"]').click();
  await expect(page.locator('.frame-readout')).toHaveText('1/1');
  const spritePngPromise = page.waitForEvent('download');
  await page.locator('[data-png-export]').click();
  const spritePng = await spritePngPromise;
  await page.locator('.sprite-png-input').setInputFiles(await spritePng.path());
  await expect(page.locator('.tool-status')).toContainText('PNG 16X16 PREVIEW');
  await saveAndCloseTool(page);

  await shellCommand(page, 'map');
  await page.locator('.map-canvas').click({ position: { x: 30, y: 30 } });
  await page.locator('[data-map="add"]').click();
  await expect(page.locator('.layer-readout')).toHaveText('2/2');
  await page.locator('[data-map="undo"]').click();
  await expect(page.locator('.layer-readout')).toHaveText('1/1');
  const tilePngPromise = page.waitForEvent('download');
  await page.locator('[data-map="png-out"]').click();
  const tilePng = await tilePngPromise;
  await page.locator('.tile-png-input').setInputFiles(await tilePng.path());
  await expect(page.locator('.tool-status')).toContainText('ATLAS IMPORTED 4 TILES');
  await saveAndCloseTool(page);

  await shellCommand(page, 'palette');
  await page.locator('.raster-line').fill('80');
  await expect(page.locator('.raster-readout')).toContainText('LINE 080');
  await saveAndCloseTool(page);

  await shellCommand(page, 'font');
  await expect(page.locator('.glyph-readout')).toContainText('$41');
  await page.locator('.font-canvas').click({ position: { x: 43, y: 43 } });
  await page.locator('[data-font="next"]').click();
  await expect(page.locator('.glyph-readout')).toContainText('$42');
  await page.locator('[data-font="undo"]').click();
  await page.getByLabel('Font preview text').fill('AB?');
  const fontPromise = page.waitForEvent('download');
  await page.locator('[data-font-export]').click();
  const fontFile = await fontPromise;
  await page.locator('.font-file-input').setInputFiles(await fontFile.path());
  await expect(page.locator('.tool-status')).toContainText('FONT IMPORTED 95 GLYPHS');
  await saveAndCloseTool(page);

  await shellCommand(page, 'sfx');
  await page.locator('[name="wave"]').selectOption('triangle');
  await page.locator('[name="pan"]').fill('0.4');
  const soundWavPromise = page.waitForEvent('download');
  await page.locator('[data-wav]').click();
  expect((await soundWavPromise).suggestedFilename()).toBe('blip.wav');
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

  const cartridgePngPromise = page.waitForEvent('download');
  await shellCommand(page, 'cart');
  const cartridgePng = await cartridgePngPromise;
  expect(cartridgePng.suggestedFilename()).toBe('e2e-alpha.pxc.png');
  await shellCommand(page, 'import');
  await page.locator('input[type="file"]').setInputFiles(await cartridgePng.path());
  await expect(page.locator('[data-view="shell"]')).toBeVisible();
  await expect(page.locator('.terminal')).toContainText('IMPORTED e2e-alpha');

  const htmlDownloadPromise = page.waitForEvent('download');
  await shellCommand(page, 'export');
  const htmlDownload = await htmlDownloadPromise;
  const htmlPath = await htmlDownload.path();
  expect(htmlPath).not.toBeNull();
  await expect(page.locator('.terminal')).toContainText(/EXPORTED e2e-alpha\.html \d+ BYTES/);

  const zipDownloadPromise = page.waitForEvent('download');
  await shellCommand(page, 'export zip');
  const zipDownload = await zipDownloadPromise;
  expect(zipDownload.suggestedFilename()).toBe('e2e-alpha-itch.zip');
  const zipPath = await zipDownload.path();
  expect(zipPath).not.toBeNull();
  const zipBytes = await readFile(zipPath);
  expect(zipBytes.readUInt32LE(0)).toBe(0x04034b50);
  const zipNameLength = zipBytes.readUInt16LE(26);
  expect(zipBytes.subarray(30, 30 + zipNameLength).toString()).toBe('index.html');
  const zipHtmlSize = zipBytes.readUInt32LE(18);
  const zipHtml = zipBytes
    .subarray(30 + zipNameLength, 30 + zipNameLength + zipHtmlSize)
    .toString('utf8');
  expect(zipHtml).toBe(await readFile(htmlPath, 'utf8'));

  const standalone = await context.newPage();
  const standaloneErrors: string[] = [];
  standalone.on('pageerror', (error) => standaloneErrors.push(error.message));
  standalone.on('console', (message) => {
    if (message.type() === 'error') standaloneErrors.push(message.text());
  });
  await standalone.goto('/');
  await standalone.setContent(await readFile(htmlPath, 'utf8'));
  await expect(standalone.locator('#status')).toHaveText(/^F\d{5} W\d{5}$/);
  await expect(standalone.locator('#fullscreen')).toBeVisible();
  await standalone.locator('#pause').click();
  await expect(standalone.locator('#status')).toHaveText('PAUSED');
  await standalone.locator('#pause').click();
  await expect(standalone.locator('#status')).toHaveText(/^F\d{5} W\d{5}$/);
  await standalone.locator('#reset').click();
  await expect(standalone.locator('#status')).toHaveText(/^F\d{5} W\d{5}$/);
  await standalone.locator('#source').click();
  await expect(standalone.locator('#inspector')).toBeVisible();
  await expect(standalone.locator('#source-view')).toContainText('Made by @gongahkia');
  expect(standaloneErrors).toEqual([]);
  await standalone.close();

  const embedded = await context.newPage();
  await embedded.goto('/#embed');
  await embedded.setContent(zipHtml);
  await expect(embedded.locator('html')).toHaveAttribute('data-embed', 'true');
  await expect(embedded.locator('#status')).toHaveText(/^F\d{5} W\d{5}$/);
  await expect(embedded.locator('main > header')).toBeHidden();
  await embedded.close();

  const moduleProject = testInfo.outputPath('module-project');
  await mkdir(`${moduleProject}/src`, { recursive: true });
  await writeFile(
    `${moduleProject}/cart.toml`,
    `format = 1
language = "PXCL/1"
id = "e2e-modules"
title = "E2E MODULES"
author = "@gongahkia"
version = "1.0.0"
entry = "src/main.pxl"
update_rate = 60
`,
  );
  await writeFile(
    `${moduleProject}/src/main.pxl`,
    `import src.math as math
state result: Int = 0
on update:
  result = math.twice(3)
on draw:
  clear(0)
`,
  );
  await writeFile(
    `${moduleProject}/src/math.pxl`,
    `fn twice(value: Int) -> Int:
  var result = value
  result += value
  return result
`,
  );
  const moduleCartridge = testInfo.outputPath('e2e-modules.pxc');
  execFileSync('target/debug/px240c', ['pack', moduleProject, '--output', moduleCartridge]);
  await shellCommand(page, 'import');
  await page.locator('input[type="file"]').setInputFiles(moduleCartridge);
  await expect(page.locator('.terminal')).toContainText('IMPORTED e2e-modules');
  await shellCommand(page, 'debug');
  await page.locator('[data-debug="in"]').click();
  await expect(page.locator('.debug-status')).toHaveText('PAUSED main.pxl:2 / DEPTH 0');
  await page.locator('[data-debug="in"]').click();
  await expect(page.locator('.debug-status')).toHaveText('BOOT COMPLETE');
  await page.locator('[data-debug="in"]').click();
  await expect(page.locator('.debug-status')).toHaveText('PAUSED main.pxl:4 / DEPTH 1');
  await page.locator('[data-debug="in"]').click();
  await expect(page.locator('.debug-status')).toHaveText('PAUSED math.pxl:2 / DEPTH 2');
  await expect(page.locator('.debug-output')).toContainText('MODULE src/math.pxl');
  await page.getByLabel('Breakpoint line').fill('3');
  await page.locator('[data-debug="break"]').click();
  await expect(page.locator('.debug-status')).toHaveText('BREAKPOINT math.pxl:3');
  await page.locator('[data-debug="frame"]').click();
  await expect(page.locator('.debug-status')).toHaveText('BREAK math.pxl:3 / FRAME 0');
  await page.locator('[data-debug="back"]').click();
  await expect(page.locator('[data-view="shell"]')).toBeVisible();
  await shellCommand(page, 'debug');
  await page.locator('[data-debug="frame"]').click();
  await expect(page.locator('.debug-status')).toHaveText('BREAK math.pxl:3 / FRAME 0');
  await expect(page.locator('.debug-output')).toContainText('MODULE src/math.pxl');
  await page.locator('[data-debug="back"]').click();
  await expect(page.locator('[data-view="shell"]')).toBeVisible();

  await page.evaluate(async () => navigator.serviceWorker.ready);
  await page.reload();
  await expect
    .poll(() => page.evaluate(() => navigator.serviceWorker.controller !== null))
    .toBe(true);
  await expect(page.locator('html')).toHaveAttribute('data-studio-ready', 'true');
  await context.setOffline(true);
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-studio-ready', 'true');
  await expect(page.locator('[data-view="shell"]')).toContainText('PXCL/1 READY');
  await context.setOffline(false);

  expect(browserErrors).toEqual([]);
});
