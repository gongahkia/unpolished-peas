import { HARDWARE } from './hardware';
import type { ConsoleCommand } from './protocol';

export type Waveform = 'pulse' | 'triangle' | 'saw' | 'noise' | 'wavetable';

export interface VolumeEnvelope {
  readonly attackFrames: number;
  readonly decayFrames: number;
  readonly sustainLevel: number;
  readonly releaseFrames: number;
}

export interface PitchEffect {
  readonly slideSemitonesPerFrame: number;
  readonly vibratoDepthSemitones: number;
  readonly vibratoPeriodFrames: number;
}

export interface SoundAsset {
  readonly kind: 'sound';
  readonly name: string;
  readonly waveform: Waveform;
  readonly note: number;
  readonly durationFrames: number;
  readonly volume: number;
  readonly pan: number;
  readonly duty?: number;
  readonly wavetable?: readonly number[];
  readonly envelope: VolumeEnvelope;
  readonly pitch: PitchEffect;
}

export interface TrackerCell {
  readonly note: number;
  readonly sound: string;
  readonly volume?: number;
}

export interface TrackerPattern {
  readonly rows: readonly (readonly (TrackerCell | null)[])[];
}

export interface MusicAsset {
  readonly kind: 'music';
  readonly name: string;
  readonly framesPerRow: number;
  readonly order: readonly string[];
  readonly patterns: Readonly<Record<string, TrackerPattern>>;
  readonly loop: boolean;
}

export type AudioAsset = SoundAsset | MusicAsset;

interface Voice {
  active: boolean;
  slot: number;
  sound: string;
  note: number;
  volumeScale: number;
  ageFrames: number;
  phase: number;
  noiseState: number;
  sequence: number;
}

interface TrackerState {
  music: string;
  orderIndex: number;
  row: number;
  frameInRow: number;
}

export interface AudioFrame {
  readonly left: Float32Array;
  readonly right: Float32Array;
  readonly activeVoices: number;
  readonly tracker: TrackerInspection | null;
}

export interface TrackerInspection {
  readonly music: string;
  readonly orderIndex: number;
  readonly row: number;
  readonly frameInRow: number;
}

export interface SynthSnapshot {
  readonly revision: 1;
  readonly frame: number;
  readonly nextSequence: number;
  readonly voices: readonly Voice[];
  readonly tracker: TrackerState | null;
}

export function isSynthSnapshot(value: unknown): value is SynthSnapshot {
  if (
    !audioRecord(value) ||
    value.revision !== 1 ||
    !audioCounter(value.frame) ||
    !audioCounter(value.nextSequence) ||
    value.nextSequence < 1 ||
    !Array.isArray(value.voices) ||
    value.voices.length !== HARDWARE.audioVoices
  )
    return false;
  const nextSequence = value.nextSequence;
  if (
    !value.voices.every(
      (voice: unknown, slot: number) =>
        audioRecord(voice) &&
        typeof voice.active === 'boolean' &&
        voice.slot === slot &&
        typeof voice.sound === 'string' &&
        voice.sound.length <= HARDWARE.cartridgeCapacityBytes &&
        audioNumber(voice.note, 0, 127) &&
        audioNumber(voice.volumeScale, 0, 1) &&
        audioCounter(voice.ageFrames) &&
        audioNumber(voice.phase, 0, 1) &&
        voice.phase < 1 &&
        audioCounter(voice.noiseState) &&
        voice.noiseState > 0 &&
        voice.noiseState <= 0xffff_ffff &&
        audioCounter(voice.sequence) &&
        voice.sequence < nextSequence,
    )
  )
    return false;
  return (
    value.tracker === null ||
    (audioRecord(value.tracker) &&
      typeof value.tracker.music === 'string' &&
      value.tracker.music.length > 0 &&
      value.tracker.music.length <= HARDWARE.cartridgeCapacityBytes &&
      audioCounter(value.tracker.orderIndex) &&
      audioCounter(value.tracker.row) &&
      audioCounter(value.tracker.frameInRow))
  );
}

export function isAudioFrame(value: unknown): value is AudioFrame {
  const samples = HARDWARE.audioSampleRate / HARDWARE.frameRate;
  return (
    audioRecord(value) &&
    value.left instanceof Float32Array &&
    value.left.length === samples &&
    value.right instanceof Float32Array &&
    value.right.length === samples &&
    value.left.every((sample) => audioNumber(sample, -1, 1)) &&
    value.right.every((sample) => audioNumber(sample, -1, 1)) &&
    audioCounter(value.activeVoices) &&
    value.activeVoices <= HARDWARE.audioVoices &&
    (value.tracker === null ||
      (audioRecord(value.tracker) &&
        typeof value.tracker.music === 'string' &&
        audioCounter(value.tracker.orderIndex) &&
        audioCounter(value.tracker.row) &&
        audioCounter(value.tracker.frameInRow)))
  );
}

function audioCounter(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

function audioNumber(value: unknown, minimum: number, maximum: number): value is number {
  return (
    typeof value === 'number' && Number.isFinite(value) && value >= minimum && value <= maximum
  );
}

function audioRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** Validated oscillator and tracker data. Arbitrary PCM samples are intentionally unrepresentable. */
export class AudioAssetStore {
  private readonly entries = new Map<string, AudioAsset>();

  public constructor(assets: readonly AudioAsset[] = []) {
    for (const asset of assets) {
      if (this.entries.has(asset.name)) {
        throw new TypeError(`duplicate audio asset '${asset.name}'`);
      }
      validateAudioAsset(asset);
      this.entries.set(asset.name, asset);
    }
    for (const asset of assets) {
      if (asset.kind !== 'music') {
        continue;
      }
      for (const pattern of Object.values(asset.patterns)) {
        for (const row of pattern.rows) {
          for (const cell of row) {
            if (cell !== null && this.entries.get(cell.sound)?.kind !== 'sound') {
              throw new TypeError(`music '${asset.name}' references missing sound '${cell.sound}'`);
            }
          }
        }
      }
    }
  }

  public get(name: string): AudioAsset | undefined {
    return this.entries.get(name);
  }
}

/** Eight-voice deterministic synthesizer and eight-channel order/pattern tracker. */
export class Synthesizer {
  private readonly assets: AudioAssetStore;
  private readonly voices: Voice[];
  private frame = 0;
  private nextSequence = 1;
  private tracker: TrackerState | null = null;

  public constructor(assets = new AudioAssetStore()) {
    this.assets = assets;
    this.voices = Array.from({ length: HARDWARE.audioVoices }, (_, slot) => emptyVoice(slot));
  }

  public executeFrame(commands: readonly ConsoleCommand[]): AudioFrame {
    for (const command of commands) {
      this.executeCommand(command);
    }
    return this.finishFrame();
  }

  public finishFrame(): AudioFrame {
    this.advanceTracker();
    const sampleCount = HARDWARE.audioSampleRate / HARDWARE.frameRate;
    const left = new Float32Array(sampleCount);
    const right = new Float32Array(sampleCount);
    for (const voice of this.voices) {
      if (voice.active) {
        this.mixVoice(voice, left, right);
      }
    }
    for (const voice of this.voices) {
      if (voice.active) {
        voice.ageFrames += 1;
        const sound = this.assets.get(voice.sound);
        if (
          sound?.kind !== 'sound' ||
          voice.ageFrames >= sound.durationFrames + sound.envelope.releaseFrames
        ) {
          voice.active = false;
        }
      }
    }
    const inspection = this.inspectTracker();
    this.frame += 1;
    return {
      left,
      right,
      activeVoices: this.voices.filter((voice) => voice.active).length,
      tracker: inspection,
    };
  }

  public snapshot(): SynthSnapshot {
    return structuredClone({
      revision: 1,
      frame: this.frame,
      nextSequence: this.nextSequence,
      voices: this.voices,
      tracker: this.tracker,
    });
  }

  public restore(snapshot: unknown): void {
    if (!isSynthSnapshot(snapshot)) {
      throw new TypeError('invalid PX-240C synthesizer snapshot');
    }
    for (const voice of snapshot.voices) {
      if (voice.active && this.assets.get(voice.sound)?.kind !== 'sound')
        throw new TypeError('snapshot references a missing sound');
    }
    if (snapshot.tracker !== null) {
      const tracker = snapshot.tracker;
      const music = this.assets.get(tracker.music);
      const patternName = music?.kind === 'music' ? music.order[tracker.orderIndex] : undefined;
      if (
        music?.kind !== 'music' ||
        patternName === undefined ||
        music.patterns[patternName]?.rows[tracker.row] === undefined ||
        tracker.frameInRow >= music.framesPerRow
      )
        throw new TypeError('snapshot references an invalid tracker position');
    }
    this.frame = snapshot.frame;
    this.nextSequence = snapshot.nextSequence;
    for (let index = 0; index < this.voices.length; index += 1) {
      Object.assign(this.voices[index] as Voice, structuredClone(snapshot.voices[index]));
    }
    this.tracker = structuredClone(snapshot.tracker);
  }

  public inspectVoices(): readonly Readonly<Voice>[] {
    return structuredClone(this.voices);
  }

  public inspectTracker(): TrackerInspection | null {
    return this.tracker === null ? null : { ...this.tracker };
  }

  public executeCommand(command: ConsoleCommand): void {
    switch (command.name) {
      case 'sfx': {
        const [handle] = expectArguments(command, 1);
        this.trigger(readAssetName(handle, 'Sound'));
        return;
      }
      case 'music': {
        const [handle] = expectArguments(command, 1);
        const name = readAssetName(handle, 'Music');
        const music = this.assets.get(name);
        if (music?.kind !== 'music') {
          throw new TypeError(`missing Music asset '${name}'`);
        }
        this.tracker = { music: name, orderIndex: 0, row: 0, frameInRow: 0 };
        return;
      }
      case 'music_stop':
        expectArguments(command, 0);
        this.tracker = null;
        return;
      default:
        throw new TypeError(`unknown audio command '${command.name}'`);
    }
  }

  private trigger(soundName: string, noteOverride?: number, volumeScale = 1): void {
    const sound = this.assets.get(soundName);
    if (sound?.kind !== 'sound') {
      throw new TypeError(`missing Sound asset '${soundName}'`);
    }
    const voice =
      this.voices.find((candidate) => !candidate.active) ??
      this.voices.reduce((oldest, candidate) =>
        candidate.sequence < oldest.sequence ? candidate : oldest,
      );
    Object.assign(voice, {
      active: true,
      sound: soundName,
      note: noteOverride ?? sound.note,
      volumeScale,
      ageFrames: 0,
      phase: 0,
      noiseState: nonZeroNoiseSeed(this.frame, voice.slot, this.nextSequence),
      sequence: this.nextSequence,
    });
    this.nextSequence += 1;
  }

  private advanceTracker(): void {
    const tracker = this.tracker;
    if (tracker === null) {
      return;
    }
    const music = this.assets.get(tracker.music);
    if (music?.kind !== 'music') {
      this.tracker = null;
      return;
    }
    if (tracker.frameInRow === 0) {
      const patternName = music.order[tracker.orderIndex];
      const pattern = patternName === undefined ? undefined : music.patterns[patternName];
      const row = pattern?.rows[tracker.row];
      row?.forEach((cell) => {
        if (cell !== null) {
          this.trigger(cell.sound, cell.note, cell.volume ?? 1);
        }
      });
    }
    tracker.frameInRow += 1;
    if (tracker.frameInRow < music.framesPerRow) {
      return;
    }
    tracker.frameInRow = 0;
    tracker.row += 1;
    const patternName = music.order[tracker.orderIndex];
    const pattern = patternName === undefined ? undefined : music.patterns[patternName];
    if (pattern !== undefined && tracker.row < pattern.rows.length) {
      return;
    }
    tracker.row = 0;
    tracker.orderIndex += 1;
    if (tracker.orderIndex >= music.order.length) {
      if (music.loop) {
        tracker.orderIndex = 0;
      } else {
        this.tracker = null;
      }
    }
  }

  private mixVoice(voice: Voice, left: Float32Array, right: Float32Array): void {
    const sound = this.assets.get(voice.sound);
    if (sound?.kind !== 'sound') {
      voice.active = false;
      return;
    }
    const frameEnvelope = envelopeAt(sound, voice.ageFrames);
    const pan = Math.max(-1, Math.min(1, sound.pan));
    const leftGain = (1 - pan) / 2;
    const rightGain = (1 + pan) / 2;
    const note =
      voice.note +
      sound.pitch.slideSemitonesPerFrame * voice.ageFrames +
      triangleLfo(voice.ageFrames, sound.pitch.vibratoPeriodFrames) *
        sound.pitch.vibratoDepthSemitones;
    const phaseStep = noteFrequency(note) / HARDWARE.audioSampleRate;
    for (let index = 0; index < left.length; index += 1) {
      const oscillator = oscillatorValue(sound, voice);
      const sample = oscillator * frameEnvelope * sound.volume * voice.volumeScale * 0.24;
      left[index] = clampSample((left[index] ?? 0) + sample * leftGain);
      right[index] = clampSample((right[index] ?? 0) + sample * rightGain);
      voice.phase = (voice.phase + phaseStep) % 1;
    }
  }
}

/** Small Web Audio queue used only after an explicit host-side resume gesture. */
export class WebAudioSink {
  private readonly context: AudioContext;
  private cursor = 0;

  public constructor(context = new AudioContext({ sampleRate: HARDWARE.audioSampleRate })) {
    this.context = context;
  }

  public get state(): AudioContextState {
    return this.context.state;
  }

  public async resume(): Promise<void> {
    await this.context.resume();
    this.cursor = Math.max(this.cursor, this.context.currentTime);
  }

  public enqueue(frame: AudioFrame): void {
    if (this.context.state !== 'running') {
      return;
    }
    const buffer = this.context.createBuffer(2, frame.left.length, HARDWARE.audioSampleRate);
    buffer.getChannelData(0).set(frame.left);
    buffer.getChannelData(1).set(frame.right);
    const source = this.context.createBufferSource();
    source.buffer = buffer;
    source.connect(this.context.destination);
    this.cursor = Math.max(this.cursor, this.context.currentTime);
    source.start(this.cursor);
    this.cursor += frame.left.length / HARDWARE.audioSampleRate;
  }

  public async close(): Promise<void> {
    await this.context.close();
  }
}

function emptyVoice(slot: number): Voice {
  return {
    active: false,
    slot,
    sound: '',
    note: 0,
    volumeScale: 1,
    ageFrames: 0,
    phase: 0,
    noiseState: 1,
    sequence: 0,
  };
}

function validateAudioAsset(asset: AudioAsset): void {
  if (asset.name.length === 0) {
    throw new TypeError('audio asset names cannot be empty');
  }
  if (asset.kind === 'sound') {
    if (
      !Number.isInteger(asset.note) ||
      asset.note < 0 ||
      asset.note > 127 ||
      !Number.isSafeInteger(asset.durationFrames) ||
      asset.durationFrames < 1 ||
      asset.durationFrames > 3600 ||
      asset.volume < 0 ||
      asset.volume > 1 ||
      asset.pan < -1 ||
      asset.pan > 1 ||
      !validEnvelope(asset.envelope) ||
      !validPitch(asset.pitch)
    ) {
      throw new RangeError(`sound '${asset.name}' is outside PX-240C limits`);
    }
    if (
      asset.waveform === 'pulse' &&
      (asset.duty === undefined || asset.duty <= 0 || asset.duty >= 1)
    ) {
      throw new RangeError(`pulse sound '${asset.name}' requires a duty between zero and one`);
    }
    if (
      asset.waveform === 'wavetable' &&
      (asset.wavetable === undefined ||
        asset.wavetable.length < 4 ||
        asset.wavetable.length > 32 ||
        asset.wavetable.some((sample) => !Number.isFinite(sample) || sample < -1 || sample > 1))
    ) {
      throw new RangeError(`wavetable sound '${asset.name}' requires 4-32 normalized entries`);
    }
    return;
  }
  if (
    !Number.isSafeInteger(asset.framesPerRow) ||
    asset.framesPerRow < 1 ||
    asset.framesPerRow > 240 ||
    asset.order.length === 0 ||
    asset.order.some((name) => asset.patterns[name] === undefined)
  ) {
    throw new RangeError(`music '${asset.name}' has an invalid order list or tempo`);
  }
  for (const pattern of Object.values(asset.patterns)) {
    if (pattern.rows.length === 0 || pattern.rows.length > 256) {
      throw new RangeError(`music '${asset.name}' has an invalid pattern length`);
    }
    for (const row of pattern.rows) {
      if (row.length !== HARDWARE.trackerChannels) {
        throw new RangeError(`music '${asset.name}' patterns must have eight channels`);
      }
      for (const cell of row) {
        if (
          cell !== null &&
          (!Number.isInteger(cell.note) ||
            cell.note < 0 ||
            cell.note > 127 ||
            (cell.volume !== undefined && (cell.volume < 0 || cell.volume > 1)))
        ) {
          throw new RangeError(`music '${asset.name}' contains an invalid note`);
        }
      }
    }
  }
}

function validEnvelope(envelope: VolumeEnvelope): boolean {
  return (
    [envelope.attackFrames, envelope.decayFrames, envelope.releaseFrames].every(
      (value) => Number.isSafeInteger(value) && value >= 0 && value <= 3600,
    ) &&
    envelope.sustainLevel >= 0 &&
    envelope.sustainLevel <= 1
  );
}

function validPitch(pitch: PitchEffect): boolean {
  return (
    Number.isFinite(pitch.slideSemitonesPerFrame) &&
    Number.isFinite(pitch.vibratoDepthSemitones) &&
    Number.isSafeInteger(pitch.vibratoPeriodFrames) &&
    pitch.vibratoPeriodFrames >= 0 &&
    pitch.vibratoPeriodFrames <= 3600
  );
}

function oscillatorValue(sound: SoundAsset, voice: Voice): number {
  switch (sound.waveform) {
    case 'pulse':
      return voice.phase < (sound.duty ?? 0.5) ? 1 : -1;
    case 'triangle':
      return 1 - 4 * Math.abs(voice.phase - 0.5);
    case 'saw':
      return voice.phase * 2 - 1;
    case 'noise':
      voice.noiseState = xorshift(voice.noiseState);
      return (voice.noiseState & 0xffff) / 0x7fff - 1;
    case 'wavetable': {
      const table = sound.wavetable ?? [0];
      return table[Math.floor(voice.phase * table.length) % table.length] ?? 0;
    }
  }
}

function envelopeAt(sound: SoundAsset, age: number): number {
  const envelope = sound.envelope;
  if (envelope.attackFrames > 0 && age < envelope.attackFrames) {
    return age / envelope.attackFrames;
  }
  const decayAge = age - envelope.attackFrames;
  if (envelope.decayFrames > 0 && decayAge < envelope.decayFrames) {
    return 1 - (1 - envelope.sustainLevel) * (decayAge / envelope.decayFrames);
  }
  if (age < sound.durationFrames) {
    return envelope.sustainLevel;
  }
  if (envelope.releaseFrames === 0) {
    return 0;
  }
  return (
    envelope.sustainLevel * Math.max(0, 1 - (age - sound.durationFrames) / envelope.releaseFrames)
  );
}

function triangleLfo(frame: number, period: number): number {
  if (period === 0) {
    return 0;
  }
  const phase = (frame % period) / period;
  return 1 - 4 * Math.abs(phase - 0.5);
}

function noteFrequency(note: number): number {
  return 440 * 2 ** ((note - 69) / 12);
}

function xorshift(state: number): number {
  let value = state >>> 0;
  value ^= value << 13;
  value ^= value >>> 17;
  value ^= value << 5;
  return value >>> 0;
}

function nonZeroNoiseSeed(frame: number, slot: number, sequence: number): number {
  return ((frame + 1) * 0x9e3779b1 + (slot + 1) * 0x85ebca6b + sequence) >>> 0 || 1;
}

function clampSample(sample: number): number {
  return Math.max(-1, Math.min(1, sample));
}

function expectArguments(command: ConsoleCommand, count: 0): [];
function expectArguments(command: ConsoleCommand, count: 1): [unknown];
function expectArguments(command: ConsoleCommand, count: number): unknown[] {
  if (command.arguments.length !== count) {
    throw new TypeError(
      `${command.name} expected ${String(count)} arguments, received ${String(command.arguments.length)}`,
    );
  }
  return [...command.arguments];
}

function readAssetName(value: unknown, kind: 'Sound' | 'Music'): string {
  if (
    typeof value !== 'object' ||
    value === null ||
    !('name' in value) ||
    typeof value.name !== 'string' ||
    !('kind' in value) ||
    value.kind !== kind
  ) {
    throw new TypeError(`expected a ${kind} asset handle`);
  }
  return value.name;
}
