async (page) => {
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const ready = () => page.locator('[role="status"][data-state="ready"]').waitFor();
  await ready();
  await page.getByRole("button", {name: "Focus game", exact: true}).click();
  const pixels = await page.evaluate(async () => {
    const image = new Image();
    image.src = window.unpolishedPeas.host.captureFrame();
    await image.decode();
    const target = document.createElement("canvas");
    target.width = 240; target.height = 120;
    const context = target.getContext("2d");
    context.imageSmoothingEnabled = false;
    context.drawImage(image, 0, 0, 240, 120);
    const rgba = context.getImageData(0, 0, 240, 120).data;
    let glyphPixels = 0;
    for (let y = 8; y < 24; y += 1) for (let x = 8; x < 220; x += 1) {
      const i = (y * 240 + x) * 4;
      if (rgba[i] > 100 && rgba[i + 1] > 100 && rgba[i + 2] > 100) glyphPixels += 1;
    }
    return {ball: Array.from(rgba.slice((48 * 240 + 28) * 4, (48 * 240 + 28) * 4 + 4)), glyphPixels};
  });
  check(pixels.ball.every((value, i) => Math.abs(value - [255, 198, 74, 255][i]) <= 1), "embedded image must render its authored center pixel");
  check(pixels.glyphPixels > 100, "authored font must render a visible title");
  await page.keyboard.press("Space");
  await page.waitForFunction(() => localStorage.getItem(window.unpolishedPeas.host.storageKey("unpolished-peas.asset-workbench:recipe-progress")) !== null);
  const saved = await page.evaluate(() => localStorage.getItem(window.unpolishedPeas.host.storageKey("unpolished-peas.asset-workbench:recipe-progress")));
  check(saved.includes("AQAAAA=="), "portable game must save score 1 as four little-endian bytes");
  await page.reload();
  await ready();
  await page.getByRole("button", {name: "Focus game", exact: true}).click();
  await page.keyboard.press("Space");
  await page.waitForFunction(() => localStorage.getItem(window.unpolishedPeas.host.storageKey("unpolished-peas.asset-workbench:recipe-progress"))?.includes("AgAAAA=="));
  check(await page.evaluate(() => window.unpolishedPeas.runtime.up_browser_protocol_failure_phase()) === -1, "game must remain healthy after restart and sound playback");
  await page.screenshot({path: "asset-workbench.png"});
  await page.evaluate(() => window.unpolishedPeas.runtime.up_browser_shutdown());
  check(errors.length === 0, `browser errors: ${errors.join(", ")}`);
  return "peas-asset-workbench-passed";
}
