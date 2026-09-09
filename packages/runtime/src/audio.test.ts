import { describe, expect, it } from 'vitest';

import {
  AudioAssetStore,
  Synthesizer,
  isSynthSnapshot,
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
  it('rejects unsupported oscillators and non-finite or missing numeric patch data before rendering', () => {
    const patch = sound('invalid');
    const invalid: unknown[] = [
      { ...patch, waveform: 'sample' },
      { ...patch, volume: NaN },
      { ...patch, volume: undefined },
      { ...patch, pan: NaN },
      { ...patch, duty: NaN },
      { ...patch, pitch: { ...patch.pitch, slideSemitonesPerFrame: 1e308 } },
      { ...patch, pitch: { ...patch.pitch, vibratoDepthSemitones: 1e308 } },
    ];
    for (const value of invalid) expect(() => new AudioAssetStore([value as SoundAsset])).toThrow();
  });

  it('rejects sparse voice snapshots and active voices beyond the patch lifetime transactionally', () => {
    const synth = new Synthesizer(new AudioAssetStore([sound('tone')]));
    synth.executeCommand(command('sfx', [handle('tone', 'Sound')]));
    const before = synth.snapshot();
    expect(isSynthSnapshot({ ...before, voices: Array(8) })).toBe(false);
    const disguised = [...before.voices];
    Reflect.deleteProperty(disguised, '0');
    Object.assign(disguised, { extra: before.voices[0] });
    expect(isSynthSnapshot({ ...before, voices: disguised })).toBe(false);
    expect(() => {
      synth.restore({
        ...before,
        voices: before.voices.map((voice, index) =>
          index === 0 ? { ...voice, ageFrames: Number.MAX_SAFE_INTEGER } : voice,
        ),
      });
    }).toThrow(/voice/);
    expect(synth.snapshot()).toEqual(before);
  });

  it('validates tracker structure and finite cells before following instrument references', () => {
    const row = [{ note: 60, sound: 'tone' }, null, null, null, null, null, null, null];
    const music = {
      kind: 'music',
      name: 'song',
      framesPerRow: 1,
      order: ['p'],
      patterns: { p: { rows: [row] } },
      loop: true,
    };
    const invalid: unknown[] = [
      { ...music, loop: 1 },
      { ...music, order: Array(1) },
      { ...music, order: [null], patterns: { null: { rows: [row] } } },
      { ...music, patterns: { p: { rows: Array(1) } } },
      { ...music, patterns: { p: { rows: [Array(8)] } } },
      {
        ...music,
        patterns: { p: { rows: [[{ note: 60, sound: 'tone', volume: NaN }, ...row.slice(1)]] } },
      },
    ];
    for (const value of invalid)
      expect(() => new AudioAssetStore([sound('tone'), value as MusicAsset])).toThrow();
  });

  it('owns a validated copy of patches and renders extreme admitted pitch without non-finite state', () => {
    const patch = sound('tone');
    const store = new AudioAssetStore([patch]);
    Object.assign(patch, { volume: NaN });
    const owned = new Synthesizer(store);
    expect(
      owned.executeFrame([command('sfx', [handle('tone', 'Sound')])]).left.every(Number.isFinite),
    ).toBe(true);
    const extreme = {
      ...sound('extreme'),
      pitch: { slideSemitonesPerFrame: 1000, vibratoDepthSemitones: 1000, vibratoPeriodFrames: 2 },
    };
    const synth = new Synthesizer(new AudioAssetStore([extreme]));
    synth.executeCommand(command('sfx', [handle('extreme', 'Sound')]));
    for (let frame = 0; frame < 6; frame += 1) {
      const output = synth.finishFrame();
      expect(output.left.every(Number.isFinite)).toBe(true);
      expect(output.right.every(Number.isFinite)).toBe(true);
      expect(isSynthSnapshot(synth.snapshot())).toBe(true);
    }
  });

  it('applies voice commands immediately but advances samples and age only on frame completion', () => {
    const assets = new AudioAssetStore([sound('tone')]);
    const synthesizer = new Synthesizer(assets);
    const trigger = command('sfx', [handle('tone', 'Sound')]);
    synthesizer.executeCommand(trigger);
    expect(synthesizer.inspectVoices()[0]).toMatchObject({ active: true, ageFrames: 0, phase: 0 });
    expect(synthesizer.snapshot().frame).toBe(0);
    expect(synthesizer.finishFrame()).toEqual(new Synthesizer(assets).executeFrame([trigger]));
    expect(synthesizer.inspectVoices()[0]?.ageFrames).toBe(1);
    expect(synthesizer.snapshot().frame).toBe(1);
  });

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
