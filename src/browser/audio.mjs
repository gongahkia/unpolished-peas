import {decodeStableWav} from "./audio_asset.mjs";

export const AudioPcmFormat = Object.freeze({sampleRate: 48_000, channels: 2, bytesPerFrame: 8});

export const AudioStatus = Object.freeze({ok: 0, unavailable: -2, rejected: -3});

export function createBrowserAudio({
  AudioContext: AudioContextImpl = globalThis.AudioContext ?? globalThis.webkitAudioContext,
  sampleRate = AudioPcmFormat.sampleRate,
  maxQueuedFrames = sampleRate * 2,
  canvas,
  window: windowRef = globalThis.window,
} = {}) {
  let context = null;
  let phase = AudioContextImpl ? "awaiting_gesture" : "unavailable";
  let nextTime = 0;
  let queuedFrames = 0;
  let lastError = null;
  let nextPlayback = 1;
  const playbacks = new Map();
  const listeners = [];

  function listen(target, type, callback, options) {
    target?.addEventListener?.(type, callback, options);
    listeners.push([target, type, callback, options]);
  }

  function updatePhase() {
    if (!context) return;
    if (context.state === "running") phase = "active";
    else if (context.state === "closed") phase = "unavailable";
    else if (phase !== "resuming") phase = "suspended";
  }

  function activate() {
    if (!AudioContextImpl || phase === "unavailable") return AudioStatus.unavailable;
    try {
      context ??= new AudioContextImpl();
      context.addEventListener?.("statechange", updatePhase);
      updatePhase();
      if (context.state === "running") return AudioStatus.ok;
      phase = "resuming";
      const resumed = context.resume?.();
      if (resumed?.then) resumed.then(() => {
        updatePhase();
        if (phase !== "active") lastError = "resume_rejected";
      }).catch(() => {
        phase = "suspended";
        lastError = "resume_failed";
      });
      else updatePhase();
      return phase === "active" ? AudioStatus.ok : AudioStatus.rejected;
    } catch {
      phase = "unavailable";
      lastError = "context_creation_failed";
      return AudioStatus.unavailable;
    }
  }

  function state() {
    updatePhase();
    return phase === "active" ? AudioStatus.ok : phase === "unavailable" ? AudioStatus.unavailable : AudioStatus.rejected;
  }

  function submit(memory, source, byteLength) {
    if (!Number.isInteger(source) || !Number.isInteger(byteLength) || source < 0 || byteLength <= 0 || byteLength % AudioPcmFormat.bytesPerFrame !== 0 || source > memory.buffer.byteLength - byteLength) return AudioStatus.rejected;
    const deviceState = state();
    if (deviceState !== AudioStatus.ok) return deviceState;
    const frames = byteLength / AudioPcmFormat.bytesPerFrame;
    if (frames > maxQueuedFrames || queuedFrames + frames > maxQueuedFrames) return AudioStatus.rejected;
    try {
      const samples = new Float32Array(memory.buffer, source, frames * AudioPcmFormat.channels);
      const buffer = context.createBuffer(AudioPcmFormat.channels, frames, sampleRate);
      const left = buffer.getChannelData(0);
      const right = buffer.getChannelData(1);
      for (let index = 0; index < frames; index += 1) {
        left[index] = samples[index * 2];
        right[index] = samples[index * 2 + 1];
      }
      const node = context.createBufferSource();
      node.buffer = buffer;
      node.connect(context.destination);
      const start = Math.max(context.currentTime, nextTime);
      const duration = frames / sampleRate;
      queuedFrames += frames;
      nextTime = start + duration;
      node.onended = () => {
        queuedFrames = Math.max(0, queuedFrames - frames);
        node.disconnect?.();
      };
      node.start(start);
      return AudioStatus.ok;
    } catch {
      lastError = "submission_failed";
      return AudioStatus.rejected;
    }
  }

  function loadSound(bytes) {
    return decodeStableWav(bytes);
  }

  function playSound(sound, {volume = 1, loop = false} = {}) {
    if (!sound || sound.format !== "wav" || !Number.isInteger(sound.sampleRate) || sound.sampleRate <= 0 || !Number.isInteger(sound.frames) || sound.frames <= 0 || !(sound.samples instanceof Float32Array) || sound.samples.length !== sound.frames * 2 || !Number.isFinite(volume) || volume < 0 || volume > 1 || typeof loop !== "boolean") return {status: AudioStatus.rejected, handle: 0};
    const deviceState = state();
    if (deviceState !== AudioStatus.ok) return {status: deviceState, handle: 0};
    try {
      const buffer = context.createBuffer(2, sound.frames, sound.sampleRate);
      const left = buffer.getChannelData(0);
      const right = buffer.getChannelData(1);
      for (let frame = 0; frame < sound.frames; frame += 1) {
        left[frame] = sound.samples[frame * 2];
        right[frame] = sound.samples[frame * 2 + 1];
      }
      const node = context.createBufferSource();
      const gain = context.createGain();
      node.buffer = buffer;
      node.loop = loop;
      gain.gain.value = volume;
      node.connect(gain);
      gain.connect(context.destination);
      const handle = nextPlayback;
      nextPlayback += 1;
      const start = Math.max(context.currentTime, nextTime);
      nextTime = start + sound.frames / sound.sampleRate;
      const cleanup = () => {
        playbacks.delete(handle);
        node.disconnect?.();
        gain.disconnect?.();
      };
      node.onended = cleanup;
      playbacks.set(handle, {node, gain});
      node.start(start);
      return {status: AudioStatus.ok, handle};
    } catch {
      lastError = "sound_playback_failed";
      return {status: AudioStatus.rejected, handle: 0};
    }
  }

  function stopSound(handle) {
    const playback = playbacks.get(handle);
    if (!playback) return false;
    playbacks.delete(handle);
    playback.node.onended = null;
    try { playback.node.stop(); } catch {}
    playback.node.disconnect?.();
    playback.gain.disconnect?.();
    return true;
  }

  listen(canvas, "pointerdown", activate, {passive: true});
  listen(canvas, "keydown", activate, {passive: true});
  listen(windowRef, "keydown", activate, {passive: true});
  listen(windowRef, "touchend", activate, {passive: true});

  return {
    activate,
    state,
    submit,
    loadSound,
    playSound,
    stopSound,
    diagnostic: () => ({phase, state: state(), sampleRate, queuedFrames, lastError}),
    teardown: () => {
      for (const [target, type, callback, options] of listeners) target?.removeEventListener?.(type, callback, options);
      for (const handle of playbacks.keys()) stopSound(handle);
      context?.close?.();
      context = null;
      phase = "unavailable";
      queuedFrames = 0;
      nextTime = 0;
    },
  };
}
