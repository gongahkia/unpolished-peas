async (page) => {
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  await page.locator('[role="status"][data-state="ready"]').waitFor();
  await page.getByRole("button", {name: "Focus game", exact: true}).click();
  await page.keyboard.press("F4");
  await page.waitForFunction(() => window.unpolishedPeas.host.input().extended.active && document.activeElement?.tagName === "TEXTAREA");
  const before = await page.locator("canvas").screenshot();
  await page.keyboard.insertText("Zoë");
  await page.waitForTimeout(100);
  const after = await page.locator("canvas").screenshot();
  check(!before.equals(after), "portable browser game must draw the entered Unicode name");
  await page.keyboard.press("F4");
  await page.waitForFunction(() => !window.unpolishedPeas.host.input().extended.active && document.activeElement?.tagName === "CANVAS");
  await page.keyboard.press("Tab");
  check(await page.locator("canvas").evaluate((canvas) => document.activeElement !== canvas), "Tab must leave canvas");
  await page.screenshot({path: "input-workbench.png"});

  // After the real game used the portable capability, inspect platform event
  // normalization without an animation loop consuming the observed batch.
  await page.evaluate(async () => {
    window.unpolishedPeas.runtime.up_browser_shutdown();
    const {createBrowserInput} = await import("./input.mjs");
    const canvas = document.querySelector("canvas");
    window.testInput = createBrowserInput({canvas});
    canvas.focus();
    window.testInput.setTextInput(true);
  });
  const client = await page.context().newCDPSession(page);
  await client.send("Input.imeSetComposition", {text: "に", selectionStart: 1, selectionEnd: 1});
  let state = await page.evaluate(() => window.testInput.snapshot().extended);
  check(state.composing, "real browser IME must start preedit");
  check(state.events.some((event) => event.kind === 4 && event.text === "に"), "real IME update must retain UTF-8 preedit");
  check(!state.events.some((event) => event.kind === 2), "preedit must not be committed");
  await client.send("Input.insertText", {text: "日本"});
  state = await page.evaluate(() => window.testInput.snapshot().extended);
  check(state.events.filter((event) => event.kind === 2 && event.text === "日本").length === 1, "IME result must commit exactly once");
  check(!state.composing, "committing must end preedit");
  await client.send("Input.insertText", {text: "日本"});
  state = await page.evaluate(() => window.testInput.snapshot().extended);
  check(state.events.filter((event) => event.kind === 2 && event.text === "日本").length === 2, "later identical typing must not be discarded as a duplicate");
  await page.evaluate(() => window.testInput.read(0, 376, new WebAssembly.Memory({initial: 1})));
  await client.send("Input.imeSetComposition", {text: "未", selectionStart: 1, selectionEnd: 1});
  await client.send("Input.imeSetComposition", {text: "", selectionStart: 0, selectionEnd: 0});
  state = await page.evaluate(() => window.testInput.snapshot().extended);
  check(!state.events.some((event) => event.kind === 2), "cancelled preedit must not commit");
  check(state.events.some((event) => event.kind === 6), "IME cancellation must be observable");
  await page.evaluate(() => window.testInput.read(0, 376, new WebAssembly.Memory({initial: 1})));
  await page.evaluate(() => {
    const button = document.createElement("button");
    button.id = "leave-game"; button.textContent = "Leave game";
    document.body.appendChild(button);
  });
  await page.keyboard.down("r");
  await client.send("Input.imeSetComposition", {text: "未", selectionStart: 1, selectionEnd: 1});
  await page.locator("#leave-game").click();
  state = await page.evaluate(() => window.testInput.snapshot().extended);
  check(!state.active && !state.composing && !state.down[21], "focus loss must deactivate text and release HID R");
  check(state.events.some((event) => event.kind === 6), "focus loss must cancel preedit");
  await page.keyboard.up("r");
  await client.detach();
  await page.evaluate(() => window.testInput.teardown());
  check(await page.locator("textarea").count() === 0, "teardown must remove owned textarea");
  return "peas-input-workbench-passed";
}
