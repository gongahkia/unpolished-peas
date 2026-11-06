async (page) => {
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() => {
    window.audioLifetimeSubmissions = 0;
    window.audioLifetimeNonzero = 0;
    const wrapped = new WeakSet();
    const wrap = (imports) => {
      if (wrapped.has(imports.env)) return;
      wrapped.add(imports.env);
      const original = imports.env.up_host_audio_submit;
      imports.env.up_host_audio_submit = (pointer, length) => {
        const samples = new Float32Array(imports.env.memory.buffer, pointer, length / 4);
        if (!samples.every(Number.isFinite)) throw new Error("nonfinite host PCM");
        const nonzero = samples.some((value) => value !== 0);
        const status = original(pointer, length);
        if (status === 0) {
          window.audioLifetimeSubmissions += 1;
          if (nonzero) window.audioLifetimeNonzero += 1;
        }
        return status;
      };
    };
    for (const name of ["instantiate", "instantiateStreaming"]) {
      const original = WebAssembly[name];
      WebAssembly[name] = (...args) => { wrap(args[1]); return original.apply(WebAssembly, args); };
    }
  });
  await page.reload();
  await page.locator('[role="status"][data-state="ready"]').waitFor();
  const metric = (field) => page.evaluate((field) => window.unpolishedPeas.runtime.audio_lifetime_metric(field), field);
  check(await metric(0) === 1 && await metric(6) === 2 && await metric(7) === 1, "initial sources must be loaded once");
  check(await metric(5) === 0, "blocked autoplay must leave sources available for retry");
  await page.getByRole("button", {name: "Focus game", exact: true}).click();
  for (let i = 0; i < 12; i += 1) {
    const before = await metric(0);
    await page.keyboard.press("Space");
    await page.waitForFunction((value) => window.unpolishedPeas.runtime.audio_lifetime_metric(0) > value, before);
    check(await metric(2) === 3 && await metric(3) === 2, "scene changes must reuse source registry slots");
    check(await metric(6) === 2 && await metric(7) === 1, "only persistent UI and current-scene sources may remain loaded");
    check(await metric(5) === 1, "activated audio must start with retained/reused handles");
    await page.keyboard.press("Escape");
    await page.waitForFunction(() => window.unpolishedPeas.runtime.audio_lifetime_metric(4) === 2);
    // The following transition releases this paused stream as well.
  }
  await page.waitForFunction(() => window.audioLifetimeNonzero > 0);
  check(await page.evaluate(() => window.unpolishedPeas.runtime.up_browser_protocol_failure_phase()) === -1, "normal host must remain healthy");
  const observations = await page.evaluate(() => ({transitions: window.unpolishedPeas.runtime.audio_lifetime_metric(0), submitted: window.audioLifetimeSubmissions, nonzero: window.audioLifetimeNonzero}));
  await page.screenshot({path: "audio-lifetime.png"});
  const atShutdown = await page.evaluate(() => {
    window.unpolishedPeas.runtime.up_browser_shutdown();
    return window.audioLifetimeSubmissions;
  });
  check(await metric(8) === 1, "game must release all playback before host teardown");
  await page.waitForTimeout(100);
  check(await page.evaluate(() => window.audioLifetimeSubmissions) === atShutdown, "shutdown must stop new PCM submissions");
  check(errors.length === 0, `browser errors: ${errors.join(", ")}`);
  return {status: "peas-audio-lifetime-passed", ...observations, userAgent: await page.evaluate(() => navigator.userAgent)};
}
