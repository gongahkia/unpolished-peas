export const HARDWARE = Object.freeze({
  width: 240,
  height: 144,
  frameRate: 60,
  paletteSize: 32,
  visualCapacityBytes: 128 * 1024,
  saveCapacityBytes: 8 * 1024,
  cartridgeCapacityBytes: 256 * 1024,
  drawCommandsPerFrame: 4096,
  audioVoices: 8,
  controllerPorts: 4,
} as const);

export type HardwareProfile = typeof HARDWARE;
