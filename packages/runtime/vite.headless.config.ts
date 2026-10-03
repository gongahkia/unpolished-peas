import { defineConfig } from 'vite';

export default defineConfig({
  build: {
    emptyOutDir: false,
    lib: {
      entry: 'src/headless-cli.ts',
      formats: ['es'],
      fileName: () => 'headless-host.mjs',
    },
    minify: false,
    outDir: 'standalone',
    rollupOptions: {
      external: [/^node:/],
    },
    sourcemap: false,
  },
});
