import { expect, test } from "@playwright/test";

test("first-game wasm bundle loads without a startup exception", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  const wasmResponse = page.waitForResponse((response) => response.url().endsWith("/first-game.wasm"));

  await page.goto("/first-game/index.html");
  await expect(page).toHaveTitle("72 first game");
  await expect(page.getByRole("heading", { name: "72 first game" })).toBeVisible();
  await expect(page.getByText("Use A/D or the arrow keys to move. Press space to jump.")).toBeVisible();
  expect((await wasmResponse).status()).toBe(200);

  await page.waitForTimeout(250);
  expect(pageErrors).toEqual([]);
  await expect(page.locator("body")).not.toContainText("WASM startup failed:");
});
