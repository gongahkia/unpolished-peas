import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import { decodeRuntimeAssets, type ProjectAssetDeclaration } from './asset-codec';
import { HARDWARE } from './hardware';

const catalogs: Readonly<Record<string, Readonly<Record<string, ProjectAssetDeclaration>>>> = {
  'cinder-circuit': {
    runner: { kind: 'animation', path: 'assets/runner.m01g' },
    tiles: { kind: 'tile_set', path: 'assets/tiles.m01g' },
    world: { kind: 'map', path: 'assets/world.m01m' },
    jump: { kind: 'sound', path: 'assets/jump.m01s' },
    hurt: { kind: 'sound', path: 'assets/hurt.m01s' },
    chime: { kind: 'sound', path: 'assets/chime.m01s' },
    bass: { kind: 'sound', path: 'assets/bass.m01s' },
    theme: { kind: 'music', path: 'assets/theme.m01t' },
  },
  ashvault: {
    seeker: { kind: 'sprite', path: 'assets/seeker.m01g' },
    wraith: { kind: 'sprite', path: 'assets/wraith.m01g' },
    relic: { kind: 'sprite', path: 'assets/relic.m01g' },
    gate: { kind: 'sprite', path: 'assets/gate.m01g' },
    step: { kind: 'sound', path: 'assets/step.m01s' },
    bump: { kind: 'sound', path: 'assets/bump.m01s' },
    found: { kind: 'sound', path: 'assets/found.m01s' },
    drone: { kind: 'sound', path: 'assets/drone.m01s' },
    lament: { kind: 'music', path: 'assets/lament.m01t' },
  },
  'raster-rush': {
    car: { kind: 'sprite', path: 'assets/car.m01g' },
    beacon: { kind: 'sprite', path: 'assets/beacon.m01g' },
    motor: { kind: 'sound', path: 'assets/motor.m01s' },
    boost: { kind: 'sound', path: 'assets/boost.m01s' },
    crash: { kind: 'sound', path: 'assets/crash.m01s' },
    fanfare: { kind: 'sound', path: 'assets/fanfare.m01s' },
    race_theme: { kind: 'music', path: 'assets/race-theme.m01t' },
  },
};

describe('bundled cartridge assets', () => {
  for (const [id, catalog] of Object.entries(catalogs)) {
    it(`validates ${id} through the public asset decoder`, () => {
      const files = Object.fromEntries(
        [...Object.values(catalog).map((asset) => asset.path), 'assets/display.m01p'].map(
          (path) => [
            path,
            new Uint8Array(
              readFileSync(new URL(`../../../cartridges/${id}/${path}`, import.meta.url)),
            ),
          ],
        ),
      );
      const assets = decodeRuntimeAssets(catalog, files, 'assets/display.m01p');
      expect(assets.visualBytes).toBeGreaterThan(0);
      expect(assets.visualBytes).toBeLessThanOrEqual(HARDWARE.visualCapacityBytes);
      expect(assets.audio.length).toBeGreaterThan(0);
      if (id === 'cinder-circuit') {
        const world = assets.visual.find((asset) => asset.name === 'world');
        expect(world?.kind).toBe('map');
        if (world?.kind === 'map') {
          expect(world.layers[0]?.width).toBe(256);
          expect(world.layers[0]?.cells.filter((tile) => tile === 5)).toHaveLength(1);
        }
        expect(assets.visualBytes).toBe(9_766);
      }
    });
  }
});
