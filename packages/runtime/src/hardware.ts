export const HARDWARE = Object.freeze({
  width: 240,
  height: 144,
  frameRate: 60,
  paletteSize: 32,
  transparentColor: 0,
  visualCapacityBytes: 128 * 1024,
  saveCapacityBytes: 8 * 1024,
  cartridgeCapacityBytes: 256 * 1024,
  drawCommandsPerFrame: 4096,
  audioVoices: 8,
  audioSampleRate: 48_000,
  trackerChannels: 8,
  controllerPorts: 4,
  spriteMaximumAxis: 64,
  tileSize: 8,
} as const);

export type HardwareProfile = typeof HARDWARE;

/** Original PX-240C RGB master palette. Logical index 0 is also the sprite transparency key. */
export const MASTER_PALETTE = Object.freeze([
  '#17141f',
  '#292532',
  '#403946',
  '#5d5054',
  '#806a63',
  '#aa8b74',
  '#d5b992',
  '#f4e5bd',
  '#5b2938',
  '#8b3c47',
  '#bf5558',
  '#ed7b69',
  '#5a3928',
  '#89572e',
  '#c18436',
  '#e7bd50',
  '#263c32',
  '#345f46',
  '#4b8b58',
  '#7fbd68',
  '#203b47',
  '#2e6571',
  '#43969a',
  '#75cbc0',
  '#243451',
  '#345581',
  '#4b7db3',
  '#73a9d1',
  '#3e3154',
  '#654777',
  '#936397',
  '#c38aae',
] as const);

export const MASTER_PALETTE_RGBA = Object.freeze(
  MASTER_PALETTE.flatMap((hex) => [
    Number.parseInt(hex.slice(1, 3), 16),
    Number.parseInt(hex.slice(3, 5), 16),
    Number.parseInt(hex.slice(5, 7), 16),
    255,
  ]),
);
