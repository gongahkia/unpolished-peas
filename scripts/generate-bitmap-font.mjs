import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { glyphRows } from '../packages/runtime/src/font.ts';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = resolve(root, 'apps/studio/public/px240c.ttf');
const unitsPerEm = 1024;
const pixel = 128;
const advance = 6 * pixel;
const glyphCharacters = [
  '?',
  ...Array.from({ length: 95 }, (_, index) => String.fromCharCode(32 + index)),
];

function bytes(...values) {
  return Uint8Array.from(values);
}

function concat(...parts) {
  const result = new Uint8Array(parts.reduce((length, part) => length + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

function u16(value) {
  return bytes((value >>> 8) & 0xff, value & 0xff);
}

function i16(value) {
  return u16(value & 0xffff);
}

function u32(value) {
  return bytes((value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff);
}

function tag(value) {
  return Uint8Array.from(value, (character) => character.charCodeAt(0));
}

function pad4(value) {
  return concat(value, new Uint8Array((4 - (value.length % 4)) % 4));
}

function checksum(value) {
  const padded = pad4(value);
  let sum = 0;
  for (let offset = 0; offset < padded.length; offset += 4) {
    sum =
      (sum +
        (((padded[offset] ?? 0) << 24) |
          ((padded[offset + 1] ?? 0) << 16) |
          ((padded[offset + 2] ?? 0) << 8) |
          (padded[offset + 3] ?? 0))) >>>
      0;
  }
  return sum;
}

function setU32(target, offset, value) {
  target[offset] = (value >>> 24) & 0xff;
  target[offset + 1] = (value >>> 16) & 0xff;
  target[offset + 2] = (value >>> 8) & 0xff;
  target[offset + 3] = value & 0xff;
}

function popCount(value) {
  let remaining = value;
  let count = 0;
  while (remaining !== 0) {
    count += remaining & 1;
    remaining >>>= 1;
  }
  return count;
}

function glyph(character) {
  const contours = [];
  for (const [row, bits] of glyphRows(character).entries()) {
    for (let column = 0; column < 5; column += 1) {
      if ((bits & (1 << (4 - column))) === 0) continue;
      const left = column * pixel;
      const right = left + pixel;
      const bottom = (6 - row) * pixel;
      const top = bottom + pixel;
      contours.push([
        [left, bottom],
        [left, top],
        [right, top],
        [right, bottom],
      ]);
    }
  }
  if (contours.length === 0) return new Uint8Array();
  const points = contours.flat();
  const endpoints = contours.map((_, index) => u16(index * 4 + 3));
  const xCoordinates = [];
  const yCoordinates = [];
  let previousX = 0;
  let previousY = 0;
  for (const [x, y] of points) {
    xCoordinates.push(i16(x - previousX));
    yCoordinates.push(i16(y - previousY));
    previousX = x;
    previousY = y;
  }
  return concat(
    i16(contours.length),
    i16(0),
    i16(0),
    i16(5 * pixel),
    i16(7 * pixel),
    ...endpoints,
    u16(0),
    new Uint8Array(points.length).fill(1),
    ...xCoordinates,
    ...yCoordinates,
  );
}

function glyphTables() {
  const locations = [];
  const parts = [];
  let offset = 0;
  let maximumContours = 0;
  for (const character of glyphCharacters) {
    locations.push(offset);
    const data = pad4(glyph(character));
    maximumContours = Math.max(
      maximumContours,
      glyphRows(character).reduce((count, row) => count + popCount(row), 0),
    );
    parts.push(data);
    offset += data.length;
  }
  locations.push(offset);
  return { glyf: concat(...parts), loca: concat(...locations.map(u32)), maximumContours };
}

function cmapTable() {
  const subtable = concat(
    u16(4),
    u16(32),
    u16(0),
    u16(4),
    u16(4),
    u16(1),
    u16(0),
    u16(126),
    u16(0xffff),
    u16(0),
    u16(32),
    u16(0xffff),
    i16(1 - 32),
    i16(1),
    u16(0),
    u16(0),
  );
  return concat(u16(0), u16(1), u16(3), u16(1), u32(12), subtable);
}

function nameTable() {
  const names = [
    [1, 'PX-240C Bitmap'],
    [2, 'Regular'],
    [4, 'PX-240C Bitmap'],
    [5, 'Version 1.0'],
    [6, 'PX-240C-Bitmap'],
  ];
  const strings = [];
  const records = [];
  let offset = 0;
  for (const [nameId, value] of names) {
    const encoded = concat(...Array.from(value, (character) => u16(character.charCodeAt(0))));
    records.push(
      concat(u16(3), u16(1), u16(0x0409), u16(nameId), u16(encoded.length), u16(offset)),
    );
    strings.push(encoded);
    offset += encoded.length;
  }
  return concat(u16(0), u16(names.length), u16(6 + names.length * 12), ...records, ...strings);
}

function buildFont() {
  const { glyf, loca, maximumContours } = glyphTables();
  const glyphCount = glyphCharacters.length;
  const tables = new Map([
    [
      'OS/2',
      concat(
        u16(0),
        i16(advance),
        u16(400),
        u16(5),
        u16(0),
        i16(650),
        i16(600),
        i16(0),
        i16(75),
        i16(650),
        i16(600),
        i16(0),
        i16(350),
        i16(64),
        i16(448),
        i16(0),
        new Uint8Array(10),
        u32(1),
        u32(0),
        u32(0),
        u32(0),
        tag('PX24'),
        u16(0x40),
        u16(32),
        u16(126),
        i16(7 * pixel),
        i16(0),
        i16(pixel),
        u16(7 * pixel),
        u16(0),
      ),
    ],
    ['cmap', cmapTable()],
    ['glyf', glyf],
    [
      'head',
      concat(
        u32(0x00010000),
        u32(0x00010000),
        u32(0),
        u32(0x5f0f3cf5),
        u16(3),
        u16(unitsPerEm),
        new Uint8Array(16),
        i16(0),
        i16(0),
        i16(5 * pixel),
        i16(7 * pixel),
        u16(0),
        u16(8),
        i16(2),
        i16(1),
        i16(0),
      ),
    ],
    [
      'hhea',
      concat(
        u32(0x00010000),
        i16(7 * pixel),
        i16(0),
        i16(pixel),
        u16(advance),
        i16(0),
        i16(pixel),
        i16(5 * pixel),
        i16(1),
        i16(0),
        i16(0),
        new Uint8Array(8),
        i16(0),
        u16(glyphCount),
      ),
    ],
    ['hmtx', concat(...Array.from({ length: glyphCount }, () => concat(u16(advance), i16(0))))],
    ['loca', loca],
    [
      'maxp',
      concat(
        u32(0x00010000),
        u16(glyphCount),
        u16(maximumContours * 4),
        u16(maximumContours),
        u16(0),
        u16(0),
        u16(2),
        u16(0),
        u16(0),
        u16(0),
        u16(0),
        u16(0),
        u16(0),
        u16(0),
        u16(0),
      ),
    ],
    ['name', nameTable()],
    [
      'post',
      concat(u32(0x00030000), u32(0), i16(-64), i16(32), u32(1), u32(0), u32(0), u32(0), u32(0)),
    ],
  ]);
  const sorted = [...tables.entries()].sort(([left], [right]) =>
    left < right ? -1 : left > right ? 1 : 0,
  );
  const numberOfTables = sorted.length;
  const maximumPower = 2 ** Math.floor(Math.log2(numberOfTables));
  const headerSize = 12 + numberOfTables * 16;
  let tableOffset = headerSize;
  const records = [];
  const bodies = [];
  let headOffset = 0;
  for (const [tableTag, data] of sorted) {
    const padded = pad4(data);
    records.push(concat(tag(tableTag), u32(checksum(data)), u32(tableOffset), u32(data.length)));
    bodies.push(padded);
    if (tableTag === 'head') headOffset = tableOffset;
    tableOffset += padded.length;
  }
  const font = concat(
    u32(0x00010000),
    u16(numberOfTables),
    u16(maximumPower * 16),
    u16(Math.log2(maximumPower)),
    u16(numberOfTables * 16 - maximumPower * 16),
    ...records,
    ...bodies,
  );
  setU32(font, headOffset + 8, (0xb1b0afba - checksum(font)) >>> 0);
  return font;
}

await mkdir(dirname(output), { recursive: true });
await writeFile(output, buildFont());
