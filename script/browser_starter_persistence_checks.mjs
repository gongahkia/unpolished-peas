async (page) => {
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  await page.addInitScript(() => {
    window.storageCalls = [];
    const wrapped = new WeakSet();
    const wrap = (imports) => {
      const env = imports.env;
      if (wrapped.has(env)) return;
      wrapped.add(env);
      for (const operation of ["read", "write"]) {
        const name = `up_host_storage_${operation}`, original = env[name];
        env[name] = (...args) => {
          const key = new TextDecoder().decode(new Uint8Array(env.memory.buffer, args[0], args[1]));
          const status = original(...args);
          window.storageCalls.push({operation, key, status});
          return status;
        };
      }
    };
    for (const name of ["instantiate", "instantiateStreaming"]) {
      const original = WebAssembly[name];
      WebAssembly[name] = (...args) => { wrap(args[1]); return original.apply(WebAssembly, args); };
    }
  });
  await page.reload();
  await page.locator('[role="status"][data-state="ready"]').waitFor();
  await page.getByRole("button", {name: "Focus game", exact: true}).click();
  await page.keyboard.down("ArrowRight");
  await page.keyboard.down("ArrowDown");
  // Observe the real game's HUD rather than assuming a wall-clock delay
  // produced a pickup. The six-character prefix is "SEEDS ".
  const waitForOne = async (x) => {
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const matches = await page.evaluate(async (x) => {
        const image = new Image(); image.src = window.unpolishedPeas.host.captureFrame(); await image.decode();
        const canvas = document.createElement("canvas"); canvas.width = 160; canvas.height = 90;
        const ctx = canvas.getContext("2d"); ctx.imageSmoothingEnabled = false; ctx.drawImage(image, 0, 0, 160, 90);
        const pixels = ctx.getImageData(x, 2, 5, 7).data;
        return [4, 12, 4, 4, 4, 4, 14].every((bits, y) => Array.from({length: 5}, (_, column) => (pixels[(y * 5 + column) * 4] > 200) === Boolean(bits & (1 << (4 - column)))).every(Boolean));
      }, x);
      if (matches) return;
      await page.waitForTimeout(25);
    }
    throw new Error(`starter HUD must render digit 1 at ${x}`);
  };
  await waitForOne(40);
  await page.keyboard.up("ArrowRight");
  await page.keyboard.up("ArrowDown");
  const state = await page.evaluate(() => ({
    saved: localStorage.getItem(window.unpolishedPeas.host.storageKey("your-name.seed-sprint:best-score")),
    failure: window.unpolishedPeas.runtime.up_browser_protocol_failure_phase(),
    keys: Object.fromEntries(Object.keys(localStorage).map((key) => [key, localStorage.getItem(key)])),
    storage: window.unpolishedPeas.host.storage(),
    calls: window.storageCalls,
  }));
  await page.screenshot({path: "starter-before-reload.png"});
  console.log(`starter after collecting a seed: ${JSON.stringify(state)}`);
  check(state.failure === -1, "starter gameplay must succeed before checking persistence");
  check(state.saved === "UPST1:AQAAAA==", `starter must persist its earned best score; observed ${JSON.stringify(state)}`);
  await page.reload();
  await page.locator('[role="status"][data-state="ready"]').waitFor();
  await waitForOne(88);
  await page.screenshot({path: "starter-after-reload.png"});
  return "peas-starter-persistence-passed";
}
