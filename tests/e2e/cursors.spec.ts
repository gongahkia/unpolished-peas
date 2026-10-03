import { expect, test, type Locator, type Page } from '@playwright/test';

async function shellCommand(page: Page, command: string): Promise<void> {
  const input = page.getByLabel('MOD-01 command');
  await expect(input).toBeEnabled();
  await input.fill(command);
  await input.press('Enter');
}

async function cursor(locator: Locator): Promise<string> {
  return locator.evaluate((element) => getComputedStyle(element).cursor);
}

test('renders Kenney pixel cursors across Studio and the player HUD', async ({
  page,
}, testInfo) => {
  await page.goto('/');
  await expect(page.locator('.boot-skip')).toBeVisible();

  const monitor = await cursor(page.locator('#studio'));
  const action = await cursor(page.locator('.boot-skip'));
  await expect(page.locator('html')).toHaveAttribute('data-studio-ready', 'true');
  const text = await cursor(page.getByLabel('MOD-01 command'));
  expect(monitor).toContain('data:image/png');
  expect(action).toContain('data:image/png');
  expect(text).toContain('data:image/png');
  expect(action).not.toBe(monitor);
  expect(text).not.toBe(monitor);

  await shellCommand(page, 'new cursor-qa CURSOR QA');
  await shellCommand(page, 'run');
  await expect(page.locator('[data-view="player"]')).toBeVisible();
  await expect(page.locator('.player-status')).toHaveText(/^F\d{5} W\d{5}$/);

  const canvas = await cursor(page.locator('.player-screen'));
  const playerAction = await cursor(page.locator('.stop-player'));
  const wait = await page.locator('.enable-player-audio').evaluate((element) => {
    (element as HTMLButtonElement).disabled = true;
    return getComputedStyle(element).cursor;
  });
  expect(canvas).toContain('data:image/png');
  expect(playerAction).toContain('data:image/png');
  expect(wait).toContain('data:image/png');
  expect(canvas).not.toBe(monitor);
  expect(playerAction).not.toBe(monitor);
  expect(wait).not.toBe(playerAction);

  await page.screenshot({ path: testInfo.outputPath('cursor-player-hud.png') });
});
