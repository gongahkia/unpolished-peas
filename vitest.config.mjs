import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    exclude: ['**/dist/**', '**/node_modules/**', '**/tests/e2e/**'],
    maxWorkers: 4,
    testTimeout: 15_000,
  },
});
