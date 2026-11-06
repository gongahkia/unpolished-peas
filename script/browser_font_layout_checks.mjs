async (page) => {
  const check = (value, message) => { if (!value) throw new Error(message); };
  await page.locator('[role="status"][data-state="ready"]').waitFor();
  await page.getByRole("button", {name: "Focus game", exact: true}).click();
  const sample = () => page.evaluate(async () => {
    const image = new Image();
    image.src = window.unpolishedPeas.host.captureFrame();
    await image.decode();
    const target = document.createElement("canvas");
    target.width = 320; target.height = 180;
    const context = target.getContext("2d");
    context.imageSmoothingEnabled = false;
    context.drawImage(image, 0, 0, 320, 180);
    const data = context.getImageData(0, 0, 320, 180).data;
    const at = (x, y) => Array.from(data.slice((y * 320 + x) * 4, (y * 320 + x) * 4 + 3));
    let glyphs = 0;
    let dialogueHash = 2166136261;
    for (let y = 36; y < 149; y += 1) for (let x = 8; x < 307; x += 1) {
      const i = (y * 320 + x) * 4;
      if (data[i] > 150 && data[i + 1] > 150 && data[i + 2] > 150) glyphs += 1;
      if (x >= 136) dialogueHash = Math.imul(dialogueHash ^ data[i], 16777619) >>> 0;
    }
    return {first: at(10, 40), second: at(10, 70), glyphs, dialogueHash};
  });
  const until = async (predicate) => {
    for (let i = 0; i < 40; i += 1) {
      const value = await sample();
      if (predicate(value)) return value;
      await page.waitForTimeout(50);
    }
    throw new Error("prepared text frame did not reach its expected state");
  };
  const initial = await until((value) => value.first.join() === "53,79,80" && value.glyphs > 200);
  await page.keyboard.press("ArrowDown");
  await until((value) => value.first.join() === "17,24,32" && value.second.join() === "53,79,80");
  await page.keyboard.press("Space");
  await until((value) => value.dialogueHash !== initial.dialogueHash);
  check(await page.evaluate(() => window.unpolishedPeas.runtime.up_browser_protocol_failure_phase()) === -1, "font layout game must remain healthy");
  await page.screenshot({path: "font-layout.png"});
  return {status: "peas-font-layout-passed", glyphs: initial.glyphs, userAgent: await page.evaluate(() => navigator.userAgent)};
}
