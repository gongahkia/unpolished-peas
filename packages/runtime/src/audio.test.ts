import { describe, expect, it } from 'vitest';

import {
  AudioAssetStore,
  Synthesizer,
  type MusicAsset,
  type SoundAsset,
  type TrackerCell,
  type Waveform,
} from './audio';
import { HARDWARE } from './hardware';
import type { ConsoleCommand } from './protocol';

const sourceSpan = { start: 0, end: 1 };

function sound(name: string, waveform: Waveform = 'pulse'): SoundAsset {
  return {
    kind: 'sound',
    name,
    waveform,
    note: 69,
    durationFrames: 4,
    volume: 1,
    pan: 0,
    ...(waveform === 'pulse' ? { duty: 0.5 } : {}),
    ...(waveform === 'wavetable' ? { wavetable: [-1, -0.25, 0.25, 1] } : {}),
    envelope: { attackFrames: 0, decayFrames: 0, sustainLevel: 1, releaseFrames: 1 },
    pitch: {
      slideSemitonesPerFrame: 0,
      vibratoDepthSemitones: 0,
      vibratoPeriodFrames: 0,
    },
  };
}

function command(name: string, arguments_: readonly unknown[]): ConsoleCommand {
  return { name, arguments: arguments_, sourceSpan };
}

function handle(name: string, kind: 'Sound' | 'Music'): object {
  return { name, kind };
}

describe('PX-240C synthesizer and tracker', () => {
  it('generates every oscillator source without arbitrary sample assets', () => {
    for (const waveform of ['pulse', 'triangle', 'saw', 'noise', 'wavetable'] as const) {
      const patch = sound(waveform, waveform);
      const synthesizer = new Synthesizer(new AudioAssetStore([patch]));
      const frame = synthesizer.executeFrame([command('sfx', [handle(patch.name, 'Sound')])]);
      expect(frame.left).toHaveLength(HARDWARE.audioSampleRate / HARDWARE.frameRate);
      expect(frame.left.some((sample) => sample !== 0)).toBe(true);
      expect(frame.left).toEqual(frame.right);
      expect(frame.activeVoices).toBe(1);
    }
  });

  it('caps output at eight voices with deterministic oldest-voice stealing', () => {
    const patch = sound('tone');
    const synthesizer = new Synthesizer(new AudioAssetStore([patch]));
    synthesizer.executeFrame(
      Array.from({ length: HARDWARE.audioVoices + 1 }, () =>
        command('sfx', [handle('tone', 'Sound')]),
      ),
    );
    const sequences = synthesizer
      .inspectVoices()
      .map((voice) => voice.sequence)
      .sort((left, right) => left - right);
    expect(sequences).toEqual([2, 3, 4, 5, 6, 7, 8, 9]);
  });

  it('plays an eight-channel pattern/order list and stops non-looping music', () => {
    const patch = sound('lead');
    const emptyRow: (TrackerCell | null)[] = Array.from(
      { length: HARDWARE.trackerChannels },
      () => null,
    );
    const noteRow = [...emptyRow];
    noteRow[0] = { note: 72, sound: 'lead', volume: 0.5 };
    const music: MusicAsset = {
      kind: 'music',
      name: 'theme',
      framesPerRow: 2,
      order: ['intro'],
      patterns: { intro: { rows: [noteRow] } },
      loop: false,
    };
    const synthesizer = new Synthesizer(new AudioAssetStore([patch, music]));
    const first = synthesizer.executeFrame([command('music', [handle('theme', 'Music')])]);
    expect(first.tracker).toMatchObject({ orderIndex: 0, row: 0, frameInRow: 1 });
    const second = synthesizer.executeFrame([]);
    expect(second.tracker).toBeNull();
    expect(synthesizer.inspectVoices().some((voice) => voice.note === 72)).toBe(true);
  });

  it('restores oscillator, noise, voice-allocation, and tracker state exactly', () => {
    const patch = sound('noise', 'noise');
    const synthesizer = new Synthesizer(new AudioAssetStore([patch]));
    synthesizer.executeFrame([command('sfx', [handle('noise', 'Sound')])]);
    const snapshot = synthesizer.snapshot();
    const expected = synthesizer.executeFrame([]);
    synthesizer.restore(snapshot);
    const replayed = synthesizer.executeFrame([]);
    expect(replayed.activeVoices).toBe(expected.activeVoices);
    expect(replayed.left).toEqual(expected.left);
    expect(replayed.right).toEqual(expected.right);
  });

  it('rejects invalid patches, tracker channel counts, and missing instruments', () => {
    expect(() => new AudioAssetStore([{ ...sound('bad'), note: 128 }])).toThrow(/limits/);
    expect(
      () =>
        new AudioAssetStore([
          {
            kind: 'music',
            name: 'bad-song',
            framesPerRow: 1,
            order: ['p'],
            patterns: { p: { rows: [[{ note: 60, sound: 'missing' }]] } },
            loop: false,
          },
        ]),
    ).toThrow(/eight channels/);
  });
});
