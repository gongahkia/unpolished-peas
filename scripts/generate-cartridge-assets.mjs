/* global process */

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function writeJson(relativePath, value) {
  const target = resolve(root, relativePath);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, `${JSON.stringify(value)}\n`);
}

function sound(waveform, note, durationFrames, volume, extra = {}) {
  return {
    revision: 1,
    kind: 'sound',
    waveform,
    note,
    durationFrames,
    volume,
    pan: 0,
    duty: waveform === 'pulse' ? 0.35 : undefined,
    envelope: { attackFrames: 1, decayFrames: 3, sustainLevel: 0.62, releaseFrames: 4 },
    pitch: {
      slideSemitonesPerFrame: 0,
      vibratoDepthSemitones: 0,
      vibratoPeriodFrames: 0,
    },
    ...extra,
  };
}

function tracker(framesPerRow, order, patterns) {
  return { revision: 1, kind: 'music', framesPerRow, order, patterns, loop: true };
}

function row(...cells) {
  return [...cells, ...Array.from({ length: 8 - cells.length }, () => null)];
}

function display(raster = []) {
  return {
    revision: 1,
    kind: 'display',
    remap: Array.from({ length: 32 }, (_, index) => index),
    raster,
  };
}

function cinderCircuit() {
  const path = 'cartridges/cinder-circuit/assets';
  const runnerA = [
    0, 0, 15, 15, 0, 0, 0, 0, 0, 15, 7, 7, 15, 0, 0, 0, 0, 15, 11, 7, 11, 15, 0, 0, 0,
    0, 11, 11, 11, 0, 0, 0, 0, 11, 15, 11, 15, 11, 0, 0, 11, 11, 15, 15, 11, 11, 0, 0, 0, 15,
    0, 0, 15, 0, 0, 0, 11, 11, 0, 0, 11, 11, 0,
  ];
  const runnerB = [
    0, 0, 15, 15, 0, 0, 0, 0, 0, 15, 7, 7, 15, 0, 0, 0, 0, 15, 11, 7, 11, 15, 0, 0, 0,
    0, 11, 11, 11, 0, 0, 0, 0, 11, 15, 11, 15, 11, 0, 0, 0, 11, 15, 15, 11, 0, 0, 0, 11, 11,
    0, 0, 11, 11, 0, 0, 0, 15, 0, 0, 0, 15, 0,
  ];
  writeJson(`${path}/runner.pxg`, {
    revision: 1,
    kind: 'sprite',
    width: 8,
    height: 8,
    frames: [runnerA, runnerB],
  });

  const tile = (draw) => {
    const pixels = Array(64).fill(0);
    for (let y = 0; y < 8; y += 1) for (let x = 0; x < 8; x += 1) pixels[y * 8 + x] = draw(x, y);
    return pixels;
  };
  const tiles = [
    tile(() => 0),
    tile((x, y) => ((x + y * 3) % 7 === 0 ? 9 : 8)),
    tile((x, y) => (y < 2 ? 19 : (x + y) % 5 === 0 ? 14 : 12)),
    tile((x, y) => (y < 2 || x === 0 || x === 7 ? 22 : 20)),
    tile((x, y) => (y > 2 && (x + y) % 4 < 2 ? 11 : 8)),
    tile((x, y) => (x === 3 || x === 4 ? (y % 2 === 0 ? 23 : 27) : 0)),
  ];
  writeJson(`${path}/tiles.pxg`, { revision: 1, kind: 'tile_set', tiles, flags: [0, 1, 1, 1, 4, 2] });

  const width = 64;
  const height = 18;
  const cells = Array(width * height).fill(0);
  for (let x = 0; x < width; x += 1) {
    cells[16 * width + x] = 2;
    cells[17 * width + x] = 1;
  }
  for (const [start, end] of [
    [11, 13],
    [21, 23],
    [31, 34],
    [41, 43],
    [51, 54],
  ]) {
    for (let x = start; x < end; x += 1) cells[16 * width + x] = 4;
  }
  for (const [y, start, end] of [
    [13, 6, 11],
    [11, 15, 20],
    [14, 25, 31],
    [10, 34, 40],
    [13, 44, 50],
    [9, 54, 59],
  ]) {
    for (let x = start; x < end; x += 1) cells[y * width + x] = 3;
  }
  cells[15 * width + 61] = 5;
  writeJson(`${path}/world.pxm`, {
    revision: 1,
    kind: 'map',
    layers: [{ width, height, cells, tileSet: 'tiles' }],
  });
  writeJson(`${path}/display.pxp`, display());
  writeJson(`${path}/jump.pxs`, sound('pulse', 72, 7, 0.45, { pitch: { slideSemitonesPerFrame: 0.8, vibratoDepthSemitones: 0, vibratoPeriodFrames: 0 } }));
  writeJson(`${path}/hurt.pxs`, sound('noise', 35, 14, 0.48));
  writeJson(`${path}/chime.pxs`, sound('triangle', 84, 12, 0.42));
  writeJson(`${path}/bass.pxs`, sound('saw', 40, 9, 0.22));
  writeJson(
    `${path}/theme.pxt`,
    tracker(9, ['A', 'B'], {
      A: { rows: [row({ note: 52, sound: 'jump' }, { note: 40, sound: 'bass' }), row({ note: 55, sound: 'jump' }), row({ note: 59, sound: 'jump' }, { note: 43, sound: 'bass' }), row({ note: 64, sound: 'jump' })] },
      B: { rows: [row({ note: 59, sound: 'jump' }, { note: 40, sound: 'bass' }), row({ note: 55, sound: 'jump' }), row({ note: 52, sound: 'jump' }, { note: 36, sound: 'bass' }), row({ note: 47, sound: 'jump' })] },
    }),
  );
}

cinderCircuit();
process.stdout.write('generated cartridge assets\n');
