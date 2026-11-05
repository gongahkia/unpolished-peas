async (page) => {
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  await page.addInitScript(() => {
    window.audioSubmissions = 0;
    window.rejectProgressWrites = false;
    const setItem = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      if (window.rejectProgressWrites && key.endsWith(":progress")) throw new DOMException("fixture quota rejection", "QuotaExceededError");
      return setItem.call(this, key, value);
    };
    const wrapped = new WeakSet();
    const wrap = (imports) => {
      if (wrapped.has(imports.env)) return;
      wrapped.add(imports.env);
      const original = imports.env.up_host_audio_submit;
      imports.env.up_host_audio_submit = (...args) => {
        const status = original(...args);
        if (status === 0) window.audioSubmissions += 1;
        return status;
      };
    };
    for (const name of ["instantiate", "instantiateStreaming"]) {
      const original = WebAssembly[name];
      WebAssembly[name] = (...args) => { wrap(args[1]); return original.apply(WebAssembly, args); };
    }
  });
  await page.reload();
  const ready = async () => {
    await page.locator('[role="status"][data-state="ready"]').waitFor();
    await page.evaluate(() => {
      window.progress = () => {
        const {runtime, host} = window.unpolishedPeas;
        const pointer = runtime.conformance_snapshot();
        const view = new DataView(host.memory.buffer, pointer, 82);
        return {score: view.getUint32(4, true), one: view.getUint32(8, true), two: view.getUint32(12, true), rebound: Boolean(view.getUint8(16)), name: new TextDecoder().decode(new Uint8Array(host.memory.buffer, pointer + 18, view.getUint8(17)))};
      };
      window.savedProgress = () => localStorage.getItem(window.unpolishedPeas.host.storageKey("peas.portable-conformance:progress"));
    });
    await page.getByRole("button", {name: "Focus game", exact: true}).click();
  };
  await ready();
  const rendered = await page.evaluate(async () => {
    const {runtime, host} = window.unpolishedPeas;
    const image = new Image(); image.src = host.captureFrame();
    const x = runtime.conformance_metric(0), frame = runtime.conformance_metric(4);
    await image.decode();
    const canvas = document.createElement("canvas"); canvas.width = 320; canvas.height = 160;
    const ctx = canvas.getContext("2d"); ctx.imageSmoothingEnabled = false; ctx.drawImage(image, 0, 0, 320, 160);
    const pixels = ctx.getImageData(0, 0, 320, 160).data;
    const pixel = (x, y) => Array.from(pixels.slice((y * 320 + x) * 4, (y * 320 + x) * 4 + 4));
    let glyphs = 0;
    for (let y = 8; y < 25; y += 1) for (let x = 8; x < 200; x += 1) if (pixels[(y * 320 + x) * 4] > 100) glyphs += 1;
    return {image: pixel(28, 50), sprite: pixel(x + (frame === 0 ? 14 : 0), 54), glyphs, status: runtime.up_browser_canvas_render_status()};
  });
  const yellow = (pixel) => pixel.every((value, i) => Math.abs(value - [255, 198, 74, 255][i]) <= 1);
  check(rendered.status === 0 && yellow(rendered.image) && yellow(rendered.sprite) && rendered.glyphs > 50, "browser must render the embedded image, current atlas frame and authored font");
  check(await page.evaluate(() => window.progress().score === 0 && window.savedProgress() === null), "new consumer must start with isolated empty storage");
  await page.keyboard.down("q");
  await page.waitForFunction(() => window.unpolishedPeas.runtime.conformance_metric(0) < 120);
  await page.keyboard.up("q");
  const beforeE = await page.evaluate(() => window.unpolishedPeas.runtime.conformance_metric(0));
  await page.keyboard.down("e");
  await page.waitForFunction((x) => window.unpolishedPeas.runtime.conformance_metric(0) > x, beforeE);
  await page.keyboard.up("e");
  // Complete taps during zero-update frames must still reach named actions.
  await page.evaluate(() => window.unpolishedPeas.runtime.up_browser_set_paused(1));
  await page.keyboard.press("1"); await page.keyboard.press("2");
  await page.waitForTimeout(50);
  await page.evaluate(() => window.unpolishedPeas.runtime.up_browser_set_paused(0));
  await page.waitForFunction(() => window.progress().one === 1 && window.progress().two === 1, null, {timeout: 5000});
  check(await page.evaluate(() => window.progress().score === 3), "1 and 2 must remain distinct named actions");
  await page.keyboard.press("F5");
  await page.waitForFunction(() => window.progress().rebound);
  await page.waitForTimeout(50);
  const beforeQ = await page.evaluate(() => window.unpolishedPeas.runtime.conformance_metric(0));
  await page.keyboard.down("q"); await page.waitForTimeout(75); await page.keyboard.up("q");
  check(await page.evaluate((x) => window.unpolishedPeas.runtime.conformance_metric(0) === x, beforeQ), "old Q binding must stop moving after rebinding");
  await page.keyboard.down("r");
  await page.waitForFunction((x) => window.unpolishedPeas.runtime.conformance_metric(0) < x, beforeQ);
  await page.keyboard.up("r");
  await page.keyboard.press("F4");
  await page.waitForFunction(() => document.activeElement?.tagName === "TEXTAREA");
  const client = await page.context().newCDPSession(page);
  await client.send("Input.imeSetComposition", {text: "Zo", selectionStart: 2, selectionEnd: 2});
  await page.waitForFunction(() => window.unpolishedPeas.runtime.conformance_metric(1) === 2);
  check(await page.evaluate(() => window.progress().name === ""), "preedit must not be committed or saved");
  await client.send("Input.insertText", {text: "Zoë你好"});
  await page.waitForFunction(() => window.progress().name === "Zoë你好" && window.unpolishedPeas.runtime.conformance_metric(1) === 0);
  await client.detach();
  await page.keyboard.press("F4");
  await page.waitForFunction(() => document.activeElement?.tagName === "CANVAS");
  await page.keyboard.press("Space");
  await page.waitForFunction(() => window.progress().score === 4 && window.audioSubmissions > 0);
  const stored = await page.evaluate(() => window.savedProgress());
  await page.evaluate(() => { window.rejectProgressWrites = true; });
  await page.keyboard.press("1");
  await page.waitForFunction(() => window.progress().score === 5);
  check(await page.evaluate((old) => window.savedProgress() === old, stored), "rejected write must preserve the previous progress");
  check(await page.evaluate(() => window.unpolishedPeas.runtime.up_browser_protocol_failure_phase()) === -1, "storage failure must keep gameplay running");
  await page.evaluate(() => { window.rejectProgressWrites = false; });
  await page.keyboard.press("2");
  await page.waitForFunction(() => window.progress().score === 7 && window.savedProgress() !== null);
  await page.reload(); await ready();
  check(await page.evaluate(() => {
    const p = window.progress(); return p.score === 7 && p.one === 2 && p.two === 2 && p.rebound && p.name === "Zoë你好";
  }), "reload must restore scores, the rebound key and exact Unicode bytes");
  await page.keyboard.press("F4");
  await page.waitForFunction(() => document.activeElement?.tagName === "TEXTAREA");
  const failureIme = await page.context().newCDPSession(page);
  await failureIme.send("Input.imeSetComposition", {text: "未", selectionStart: 1, selectionEnd: 1});
  await page.waitForFunction(() => window.unpolishedPeas.runtime.conformance_metric(1) > 0);
  const lifecycle = await page.evaluate(() => {
    const {runtime, host} = window.unpolishedPeas;
    const before = runtime.conformance_cleanups();
    runtime.conformance_reject_next_init();
    const rejected = runtime.up_browser_init(320, 160);
    const failedCleanups = runtime.conformance_cleanups();
    const failedFrames = host.lifecycle().scheduledFrames;
    const failedText = host.input().extended;
    const recovered = runtime.up_browser_init(320, 160);
    return {before, rejected, failedCleanups, failedFrames, failedTextActive: failedText.active, failedComposing: failedText.composing, recovered, scheduledFrames: host.lifecycle().scheduledFrames};
  });
  await failureIme.detach();
  check(lifecycle.rejected === -3 && lifecycle.failedCleanups === lifecycle.before + 2, "reinit must clean the old game and failed partial game exactly once");
  check(lifecycle.failedFrames === 0, "failed initialization must cancel old scheduled callbacks");
  check(!lifecycle.failedTextActive && !lifecycle.failedComposing, "failed initialization must cancel the old IME session before retry");
  check(lifecycle.recovered === 0 && lifecycle.scheduledFrames === 1, "retry must recover with exactly one scheduled frame");
  check(await page.evaluate(() => window.progress().name === "Zoë你好"), "canceled preedit must not leak into restored progress");
  await page.screenshot({path: "portable-conformance.png"});
  const shutdown = await page.evaluate(() => {
    const {runtime, host} = window.unpolishedPeas;
    const before = runtime.conformance_cleanups();
    runtime.up_browser_shutdown();
    const after = runtime.conformance_cleanups();
    runtime.up_browser_shutdown();
    return {before, after, second: runtime.conformance_cleanups(), pointer: runtime.conformance_snapshot(), scheduled: host.lifecycle().scheduledFrames};
  });
  check(shutdown.after === shutdown.before + 1 && shutdown.second === shutdown.after && shutdown.pointer === 0 && shutdown.scheduled === 0, "shutdown must forward game cleanup exactly once before releasing host capabilities");
  check(await page.locator("textarea").count() === 0, "shutdown must release the text-input element");
  return "peas-portable-conformance-passed";
}
