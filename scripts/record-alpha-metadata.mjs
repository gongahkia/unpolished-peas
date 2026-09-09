import { execFileSync } from 'node:child_process';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
execFileSync('git', [
  'diff',
  '--exit-code',
  'e39be5a',
  '--',
  'apps/studio/src',
  'packages/runtime/src',
  'crates',
]);
const catalogs = {};
for (const id of ['cinder-circuit', 'ashvault', 'raster-rush']) {
  catalogs[id] = JSON.parse(
    execFileSync('target/debug/px240c', ['info', `cartridges/${id}`], { encoding: 'utf8' }),
  );
}
await writeFile('tests/fixtures/alpha/catalogs.json', `${JSON.stringify(catalogs, null, 2)}\n`, {
  flag: 'wx',
});
const bundles = {};
for (const path of await readdir('dist/studio/assets')) {
  const bytes = await readFile(`dist/studio/assets/${path}`);
  bundles[path] = { bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
}
await writeFile('tests/fixtures/alpha/bundles.json', `${JSON.stringify(bundles, null, 2)}\n`, {
  flag: 'wx',
});
