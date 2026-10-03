import { defineConfig } from 'vite';

export default defineConfig({
  build: {
    emptyOutDir: false,
    lib: {
      entry: 'src/standalone-player.ts',
      formats: ['iife'],
      name: 'MOD01Standalone',
      fileName: () => 'player.js',
    },
    minify: false,
    outDir: 'standalone',
    sourcemap: false,
  },
});
