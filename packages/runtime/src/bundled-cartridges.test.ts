import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import { decodeRuntimeAssets, type ProjectAssetDeclaration } from './asset-codec';
import { HARDWARE } from './hardware';

const catalogs: Readonly<Record<string, Readonly<Record<string, ProjectAssetDeclaration>>>> = {
  'cinder-circuit': {
    runner: { kind: 'animation', path: 'assets/runner.pxg' },
    tiles: { kind: 'tile_set', path: 'assets/tiles.pxg' },
    world: { kind: 'map', path: 'assets/world.pxm' },
    jump: { kind: 'sound', path: 'assets/jump.pxs' },
    hurt: { kind: 'sound', path: 'assets/hurt.pxs' },
    chime: { kind: 'sound', path: 'assets/chime.pxs' },
    bass: { kind: 'sound', path: 'assets/bass.pxs' },
    theme: { kind: 'music', path: 'assets/theme.pxt' },
  },
  ashvault: {
    seeker: { kind: 'sprite', path: 'assets/seeker.pxg' },
    wraith: { kind: 'sprite', path: 'assets/wraith.pxg' },
    relic: { kind: 'sprite', path: 'assets/relic.pxg' },
    gate: { kind: 'sprite', path: 'assets/gate.pxg' },
    step: { kind: 'sound', path: 'assets/step.pxs' },
    bump: { kind: 'sound', path: 'assets/bump.pxs' },
    found: { kind: 'sound', path: 'assets/found.pxs' },
    drone: { kind: 'sound', path: 'assets/drone.pxs' },
    lament: { kind: 'music', path: 'assets/lament.pxt' },
  },
  'raster-rush': {
    car: { kind: 'sprite', path: 'assets/car.pxg' },
    beacon: { kind: 'sprite', path: 'assets/beacon.pxg' },
    motor: { kind: 'sound', path: 'assets/motor.pxs' },
    boost: { kind: 'sound', path: 'assets/boost.pxs' },
    crash: { kind: 'sound', path: 'assets/crash.pxs' },
    fanfare: { kind: 'sound', path: 'assets/fanfare.pxs' },
    race_theme: { kind: 'music', path: 'assets/race-theme.pxt' },
  },
};

describe('bundled cartridge assets', () => {
  for (const [id, catalog] of Object.entries(catalogs)) {
    it(`validates ${id} through the public asset decoder`, () => {
      const files = Object.fromEntries(
        [...Object.values(catalog).map((asset) => asset.path), 'assets/display.pxp'].map((path) => [
          path,
          new Uint8Array(
            readFileSync(new URL(`../../../cartridges/${id}/${path}`, import.meta.url)),
          ),
        ]),
      );
      const assets = decodeRuntimeAssets(catalog, files, 'assets/display.pxp');
      expect(assets.visualBytes).toBeGreaterThan(0);
      expect(assets.visualBytes).toBeLessThanOrEqual(HARDWARE.visualCapacityBytes);
      expect(assets.audio.length).toBeGreaterThan(0);
    });
  }
});
