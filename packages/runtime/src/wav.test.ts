import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';

import { renderMusicWav, renderSoundWav } from './wav';
import type { MusicAsset, SoundAsset } from './audio';

const sound: SoundAsset = {
  kind: 'sound',
  name: 'tone',
  waveform: 'pulse',
  note: 60,
  durationFrames: 2,
  volume: 0.5,
  pan: 0,
  duty: 0.5,
  envelope: { attackFrames: 0, decayFrames: 0, sustainLevel: 1, releaseFrames: 1 },
  pitch: { slideSemitonesPerFrame: 0, vibratoDepthSemitones: 0, vibratoPeriodFrames: 0 },
};

describe('offline production-synth WAV', () => {
  it('writes a parseable deterministic stereo PCM sound fixture', () => {
    const wav = renderSoundWav(sound);
    const view = new DataView(wav.buffer);
    expect(new TextDecoder().decode(wav.subarray(0, 4))).toBe('RIFF');
    expect(new TextDecoder().decode(wav.subarray(8, 12))).toBe('WAVE');
    expect(view.getUint32(24, true)).toBe(48_000);
    expect(view.getUint16(22, true)).toBe(2);
    expect(view.getUint16(34, true)).toBe(16);
    expect(view.getUint32(40, true)).toBe(3 * 800 * 4);
    expect(createHash('sha256').update(wav).digest('hex')).toBe(
      '094f8a60e627c49f6c6209704bd24bb3e6c64e0517cc938b05fee1360e85c503',
    );
  });

  it('renders one tracker order through the same synthesizer', () => {
    const music: MusicAsset = {
      kind: 'music',
      name: 'song',
      framesPerRow: 2,
      order: ['00'],
      patterns: {
        '00': { rows: [[{ note: 60, sound: 'tone' }, null, null, null, null, null, null, null]] },
      },
      loop: true,
    };
    const wav = renderMusicWav(music, [sound]);
    expect(new DataView(wav.buffer).getUint32(40, true)).toBe(2 * 800 * 4);
    expect(() => renderMusicWav({ ...music, framesPerRow: 60 * 60 * 11 }, [sound])).toThrow(
      /ten minutes/,
    );
  });
});
