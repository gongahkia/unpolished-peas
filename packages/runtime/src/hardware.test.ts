import { describe, expect, it } from 'vitest';

import { HARDWARE } from './index';

describe('experimental alpha hardware profile', () => {
  it('keeps the locked display and capacity values explicit', () => {
    expect(HARDWARE).toEqual({
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
    });
  });
});
