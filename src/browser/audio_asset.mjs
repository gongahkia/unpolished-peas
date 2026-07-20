export const stableAudioAssetDiagnostic = "asset_load_failed:audio_v1";
export const stableAudioLimits = Object.freeze({maxInputBytes: 32 * 1024 * 1024, maxDecodedFrames: 4 * 1024 * 1024});

export class StableAudioAssetError extends Error {
  constructor() {
    super(stableAudioAssetDiagnostic);
    this.code = stableAudioAssetDiagnostic;
  }
}

function fail() {
  throw new StableAudioAssetError();
}

function u16(view, offset) {
  return view.getUint16(offset, true);
}

function u32(view, offset) {
  return view.getUint32(offset, true);
}

function sample(view, offset, format, bits) {
  if (format === 3) return view.getFloat32(offset, true);
  if (bits === 8) return (view.getUint8(offset) - 128) / 128;
  if (bits === 16) return view.getInt16(offset, true) / 32768;
  if (bits === 24) {
    let value = view.getUint8(offset) | (view.getUint8(offset + 1) << 8) | (view.getUint8(offset + 2) << 16);
    if (value & 0x800000) value |= 0xff000000;
    return value / 8388608;
  }
  return view.getInt32(offset, true) / 2147483648;
}

export function decodeStableWav(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length < 44 || bytes.length > stableAudioLimits.maxInputBytes) fail();
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (String.fromCharCode(...bytes.subarray(0, 4)) !== "RIFF" || String.fromCharCode(...bytes.subarray(8, 12)) !== "WAVE") fail();
  let offset = 12;
  let fmt = null;
  let data = null;
  while (offset + 8 <= bytes.length) {
    const id = String.fromCharCode(...bytes.subarray(offset, offset + 4));
    const length = u32(view, offset + 4);
    offset += 8;
    if (length > bytes.length - offset) fail();
    if (id === "fmt ") {
      if (length < 16) fail();
      fmt = {format: u16(view, offset), channels: u16(view, offset + 2), sampleRate: u32(view, offset + 4), blockAlign: u16(view, offset + 12), bits: u16(view, offset + 14)};
    } else if (id === "data") data = {offset, length};
    offset += length + (length & 1);
  }
  if (!fmt || !data || fmt.sampleRate === 0 || (fmt.channels !== 1 && fmt.channels !== 2) || !((fmt.format === 1 && [8, 16, 24, 32].includes(fmt.bits)) || (fmt.format === 3 && fmt.bits === 32))) fail();
  const bytesPerSample = fmt.bits / 8;
  if (fmt.blockAlign !== fmt.channels * bytesPerSample || data.length === 0 || data.length % fmt.blockAlign !== 0) fail();
  const frames = data.length / fmt.blockAlign;
  if (frames > stableAudioLimits.maxDecodedFrames) fail();
  const samples = new Float32Array(frames * 2);
  for (let frame = 0; frame < frames; frame += 1) {
    const source = data.offset + frame * fmt.blockAlign;
    const left = sample(view, source, fmt.format, fmt.bits);
    samples[frame * 2] = left;
    samples[frame * 2 + 1] = fmt.channels === 1 ? left : sample(view, source + bytesPerSample, fmt.format, fmt.bits);
  }
  return {format: "wav", sampleRate: fmt.sampleRate, frames, samples};
}
