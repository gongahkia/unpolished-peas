import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: false,
  workers: 1,
  reporter: 'line',
  timeout: 240_000,
  expect: { timeout: 15_000 },
  use: {
    ...devices['Desktop Firefox'],
    baseURL: 'http://127.0.0.1:4173',
    serviceWorkers: 'allow',
    trace: 'retain-on-failure',
  },
  webServer: {
    command: 'pnpm --dir apps/studio exec vite preview --host 127.0.0.1 --port 4173 --strictPort',
    url: 'http://127.0.0.1:4173',
    reuseExistingServer: false,
    timeout: 120_000,
  },
});
