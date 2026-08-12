import { expect, test } from "@playwright/test";

test("first-game wasm renders, handles input, resize, focus, and visibility", async ({ page }) => {
  const pageErrors = [];
  const consoleErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text());
  });
  const wasmResponse = page.waitForResponse((response) => response.url().endsWith("/first-game.wasm"));

  await page.goto("/first-game/index.html");
  await expect(page).toHaveTitle("72 first game");
  await expect(page.getByRole("heading", { name: "72 first game" })).toBeVisible();
  await expect(page.getByText("Use A/D or the arrow keys to move. Press space to jump.")).toBeVisible();
  expect((await wasmResponse).status()).toBe(200);

  const canvas = page.locator("canvas");
  await expect(canvas).toBeVisible();
  await expect.poll(() => canvas.evaluate((element) => element.width)).toBeGreaterThan(0);
  await page.waitForTimeout(250);
  const initial = await canvas.screenshot();

  await page.keyboard.down("ArrowRight");
  await page.waitForTimeout(100);
  await page.keyboard.up("ArrowRight");
  expect((await canvas.screenshot()).equals(initial), `console errors: ${consoleErrors.join(" | ")}`).toBe(false);

  const widthBeforeResize = await canvas.evaluate((element) => element.width);
  await page.setViewportSize({ width: 850, height: 600 });
  await expect.poll(() => canvas.evaluate((element) => element.width)).toBeLessThan(widthBeforeResize);
  const widthAfterShrink = await canvas.evaluate((element) => element.width);
  await page.setViewportSize({ width: 1280, height: 720 });
  await expect.poll(() => canvas.evaluate((element) => element.width)).toBeGreaterThan(widthAfterShrink);

  const beforeBlur = await canvas.screenshot();
  await page.evaluate(() => {
    document.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, code: "ArrowRight" }));
    window.dispatchEvent(new Event("blur"));
  });
  await page.waitForTimeout(100);
  expect((await canvas.screenshot()).equals(beforeBlur)).toBe(true);

  await page.evaluate(() => {
    Object.defineProperty(document, "hidden", { configurable: true, value: true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  const hidden = await canvas.screenshot();
  await page.waitForTimeout(100);
  expect((await canvas.screenshot()).equals(hidden)).toBe(true);
  await page.evaluate(() => {
    Object.defineProperty(document, "hidden", { configurable: true, value: false });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  const beforeVisibleInput = await canvas.screenshot();
  await page.keyboard.down("ArrowRight");
  await page.waitForTimeout(100);
  await page.keyboard.up("ArrowRight");
  expect((await canvas.screenshot()).equals(beforeVisibleInput)).toBe(false);

  expect(pageErrors).toEqual([]);
  expect(consoleErrors).toEqual([]);
  await expect(page.locator("body")).not.toContainText("WASM startup failed:");
});
