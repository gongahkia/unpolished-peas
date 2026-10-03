import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { defineConfig, type Plugin } from 'vite';

function offlineServiceWorker(): Plugin {
  return {
    name: 'mod01-offline-service-worker',
    apply: 'build',
    generateBundle(_options, bundle) {
      const publicFiles = [
        'mod01-logo.png',
        'manifest.webmanifest',
        'mod01.ttf',
        'cartridges/ashvault.m01c',
        'cartridges/cinder-circuit.m01c',
        'cartridges/raster-rush.m01c',
        'cartridges/mod01-service.m01c',
        'cartridges/signal-4k.m01c',
        'cartridges/pocket-relay.m01c',
        'cartridges/hardware-gauntlet.m01c',
        'cartridges/modl-tutorial.m01c',
      ];
      const files = [
        './',
        './index.html',
        ...publicFiles.map((path) => `./${path}`),
        ...Object.keys(bundle).map((path) => `./${path}`),
      ].sort();
      const revision = createHash('sha256');
      for (const path of files) revision.update(path);
      for (const path of publicFiles)
        revision.update(readFileSync(new URL(`./public/${path}`, import.meta.url)));
      this.emitFile({
        type: 'asset',
        fileName: 'sw.js',
        source: `const CACHE='mod01-studio-${revision.digest('hex').slice(0, 16)}';
const PRECACHE=${JSON.stringify(files)};
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(PRECACHE)).then(()=>self.skipWaiting())));
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key!==CACHE).map(key=>caches.delete(key)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',event=>{const request=event.request;if(request.method!=='GET'||new URL(request.url).origin!==self.location.origin)return;event.respondWith(caches.match(request).then(cached=>cached??fetch(request).then(response=>{if(response.ok){const copy=response.clone();void caches.open(CACHE).then(cache=>cache.put(request,copy));}return response;}).catch(()=>request.mode==='navigate'?caches.match('./index.html'):undefined)));});
`,
      });
    },
  };
}

function developmentStylePolicy(): Plugin {
  return {
    name: 'mod01-development-style-policy',
    apply: 'serve',
    transformIndexHtml(html) {
      return html.replace("style-src 'self';", "style-src 'self' 'unsafe-inline';");
    },
  };
}

export default defineConfig({
  base: './',
  plugins: [offlineServiceWorker(), developmentStylePolicy()],
  build: {
    outDir: '../../dist/studio',
    emptyOutDir: true,
  },
});
