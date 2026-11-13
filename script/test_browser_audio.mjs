import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {AudioPcmFormat, AudioStatus, createBrowserAudio} from "../src/browser/audio.mjs";

class Events {
  listeners = new Map();
  addEventListener(type, callback) { this.listeners.set(type, callback); }
  removeEventListener(type, callback) { if (this.listeners.get(type) === callback) this.listeners.delete(type); }
  emit(type) { this.listeners.get(type)?.(); }
}

class FakeAudioContext extends Events {
  static instances = [];
  state = "suspended";
  currentTime = 0;
  destination = {};
  starts = [];

  constructor() { super(); FakeAudioContext.instances.push(this); }
  resume() { this.state = "running"; this.emit("statechange"); }
  close() { this.state = "closed"; this.emit("statechange"); }
  createBuffer(channels, frames, sampleRate) {
    return {channels, frames, sampleRate, data: Array.from({length: channels}, () => new Float32Array(frames)), getChannelData(index) { return this.data[index]; }};
  }
  createBufferSource() {
    const context = this;
    return {connect() {}, disconnect() {}, start(time) { context.starts.push({time, buffer: this.buffer, node: this}); }, stop() { this.onended?.(); }};
  }
  createGain() { return {gain: {value: 1}, connect() {}, disconnect() {}}; }
}

const memory = new WebAssembly.Memory({initial: 1});
new Float32Array(memory.buffer, 0, 4).set([0.25, -0.5, 0.75, -1]);
const unavailable = createBrowserAudio({AudioContext: undefined});
assert.equal(unavailable.state(), AudioStatus.unavailable);
assert.equal(unavailable.submit(memory, 0, AudioPcmFormat.bytesPerFrame), AudioStatus.unavailable);

const canvas = new Events();
const windowRef = new Events();
const audio = createBrowserAudio({AudioContext: FakeAudioContext, canvas, window: windowRef, maxQueuedFrames: 2});
const fixture = JSON.parse(await readFile(new URL("../src/fixtures/audio/stable-audio-v1.json", import.meta.url), "utf8"));
const validWav = Uint8Array.from(Buffer.from(fixture.valid_wav_base64, "base64"));
const invalidWav = Uint8Array.from(Buffer.from(fixture.invalid_wav_base64, "base64"));
const sound = audio.loadSound(validWav);
assert.equal(sound.format, fixture.format);
assert.deepEqual([...sound.samples], [0, 0, 32767 / 32768, 32767 / 32768]);
assert.equal(audio.playSound(sound).status, AudioStatus.rejected);
assert.throws(() => audio.loadSound(invalidWav), (error) => error?.code === "asset_load_failed:audio_v1");
assert.equal(audio.state(), AudioStatus.rejected);
canvas.emit("pointerdown");
assert.equal(audio.state(), AudioStatus.ok);
assert.equal(FakeAudioContext.instances.length, 1);
assert.equal(audio.submit(memory, 0, AudioPcmFormat.bytesPerFrame * 2), AudioStatus.ok);
const context = FakeAudioContext.instances[0];
assert.deepEqual([...context.starts[0].buffer.data[0]], [0.25, 0.75]);
assert.deepEqual([...context.starts[0].buffer.data[1]], [-0.5, -1]);
assert.equal(context.starts[0].time, 0);
assert.equal(audio.diagnostic().queuedFrames, 2);
assert.equal(audio.submit(memory, 0, AudioPcmFormat.bytesPerFrame), AudioStatus.rejected);
context.starts[0].node.onended();
assert.equal(audio.diagnostic().queuedFrames, 0);
const playback = audio.playSound(sound, {volume: 0.5, loop: true});
assert.equal(playback.status, AudioStatus.ok);
assert.notEqual(playback.handle, 0);
assert.equal(context.starts[1].buffer.frames, 2);
assert.equal(context.starts[1].node.loop, true);
assert.equal(audio.stopSound(playback.handle), true);
assert.equal(audio.stopSound(playback.handle), false);
assert.deepEqual(fixture.outcomes, {load: "ok", play: "ok", stop: "ok", stop_stale: "rejected", invalid_load: "rejected"});
context.state = "suspended";
context.emit("statechange");
assert.equal(audio.state(), AudioStatus.rejected);
assert.equal(audio.activate(), AudioStatus.ok);
assert.equal(audio.submit(memory, 0, 3), AudioStatus.rejected);
audio.teardown();
assert.equal(canvas.listeners.size, 0);
assert.equal(windowRef.listeners.size, 0);
