async (page) => {
  const base = new URL(page.url());
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const ready = () => page.locator('[role="status"][data-state="ready"]').waitFor();
  await ready();
  await page.getByRole("button", {name: "Focus game", exact: true}).click();
  check(await page.locator("canvas").evaluate((canvas) => document.activeElement === canvas), "focus button must focus canvas");
  await page.keyboard.press("Tab");
  check(await page.locator("canvas").evaluate((canvas) => document.activeElement !== canvas), "Tab must leave canvas");
  await page.setViewportSize({width: 360, height: 740});
  check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "shell must fit a narrow viewport");
  check(await page.locator("canvas").getAttribute("aria-label"), "canvas needs an accessible name");

  // An unsupported request must give the player a working recovery action.
  const invalid = new URL(base);
  invalid.searchParams.set("renderer", "invalid-renderer");
  invalid.searchParams.set("preserve", "yes");
  await page.goto(invalid.href);
  await page.locator('[data-state="failed"]').waitFor();
  await page.getByRole("button", {name: "Try WebGL 2", exact: true}).click();
  await ready();
  check(new URL(page.url()).searchParams.get("preserve") === "yes", "fallback must preserve other URL settings");

  // The page must distinguish a slow load from failure, and recover on retry.
  await page.route("**/unpolished-peas.wasm", (route) => route.fulfill({status: 503, body: "unavailable"}));
  await page.reload();
  await page.locator('[data-state="failed"]').waitFor();
  check(await page.getByRole("button", {name: "Reload game", exact: true}).isVisible(), "load failure must offer retry");
  await page.unroute("**/unpolished-peas.wasm");
  await page.getByRole("button", {name: "Reload game", exact: true}).click();
  await ready();
  await page.route("**/unpolished-peas.wasm", async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 1000));
    await route.continue();
  });
  await page.reload({waitUntil: "domcontentloaded"});
  await page.locator('[data-state="loading"]').waitFor();
  await ready();
  await page.unroute("**/unpolished-peas.wasm");
  await page.setViewportSize({width: 1000, height: 800});
  return "peas-shell-checks-passed";
}
