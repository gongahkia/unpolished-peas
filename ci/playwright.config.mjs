import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "wasm-smoke.spec.mjs",
  timeout: 30_000,
  use: {
    browserName: "chromium",
    baseURL: "http://127.0.0.1:4173",
    headless: true,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  webServer: {
    command: "python3 -m http.server 4173 --directory ../dist",
    url: "http://127.0.0.1:4173/first-game/index.html",
    reuseExistingServer: !process.env.CI,
  },
});
