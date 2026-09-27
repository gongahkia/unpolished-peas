import { execFileSync } from 'node:child_process';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
const catalogs = {};
for (const id of ['cinder-circuit', 'ashvault', 'raster-rush']) {
  catalogs[id] = JSON.parse(
    execFileSync('target/debug/mod01', ['info', `cartridges/${id}`], { encoding: 'utf8' }),
  );
}
await writeFile(
  'tests/fixtures/mod01-baseline/catalogs.json',
  `${JSON.stringify(catalogs, null, 2)}\n`,
  {
    flag: 'w',
  },
);
const bundles = {};
for (const path of await readdir('dist/studio/assets')) {
  const bytes = await readFile(`dist/studio/assets/${path}`);
  bundles[path] = { bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
}
await writeFile(
  'tests/fixtures/mod01-baseline/bundles.json',
  `${JSON.stringify(bundles, null, 2)}\n`,
  {
    flag: 'w',
  },
);
