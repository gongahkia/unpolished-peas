import {PhysicalKey} from "./physical_keys.mjs";
export {PhysicalKey};
export const InputAbiV2 = Object.freeze({version: 2, byteLength: 1890, request: 0x32515055});
export const EventKind = Object.freeze({key_down: 0, key_up: 1, text_commit: 2, composition_start: 3, composition_update: 4, composition_end: 5, composition_cancel: 6, text_started: 7, text_stopped: 8});

export function createExtendedInput() {
  const down = new Array(256).fill(false), pressed = [...down], released = [...down];
  const events = [];
  let textBytes = 0, active = false, composing = false, overflow = false;
  const encoder = new TextEncoder();
  function append(kind, text = "", key = null, repeat = false) {
    let length = 0;
    for (const character of text) {
      const point = character.codePointAt(0);
      if (point >= 0xd800 && point <= 0xdfff) return false;
      length += point < 0x80 ? 1 : point < 0x800 ? 2 : point < 0x10000 ? 3 : 4;
      if (length > 1024 - textBytes) { overflow = true; return false; }
    }
    if (events.length === 32) { overflow = true; return false; }
    const bytes = encoder.encode(text);
    events.push({kind, text, bytes, key, repeat});
    textBytes += bytes.length;
    return true;
  }
  function cancel() {
    if (composing) { composing = false; append(EventKind.composition_cancel); }
  }
  function end() {
    if (composing) { composing = false; append(EventKind.composition_end); }
  }
  function start() {
    if (!active) return;
    if (!composing) { composing = true; append(EventKind.composition_start); }
  }
  function setKey(key, value, repeat = false) {
    if (key === undefined) return;
    const prior = down[key];
    if (prior === value && !(repeat && value)) return;
    down[key] = value;
    if (prior !== value) { if (value) pressed[key] = true; else released[key] = true; }
    append(value ? EventKind.key_down : EventKind.key_up, "", key, repeat && prior && value);
  }
  return {
    get active() { return active; },
    get composing() { return composing; },
    setActive(value) {
      if (active === value) return;
      if (!value) cancel();
      active = value;
      append(value ? EventKind.text_started : EventKind.text_stopped);
    },
    setKey,
    cancel, end, start,
    composition(text) { if (active) { start(); append(EventKind.composition_update, text); } },
    commit(text) { return active && append(EventKind.text_commit, text); },
    releaseAll() {
      for (const key of Object.values(PhysicalKey)) if (down[key]) setKey(key, false);
      cancel();
    },
    clearTransient() { pressed.fill(false); released.fill(false); events.length = 0; textBytes = 0; overflow = false; },
    snapshot() { return {down: [...down], pressed: [...pressed], released: [...released], active, composing, overflow, events: events.map(({bytes, ...event}) => ({...event}))}; },
    encode(view, offset) {
      for (let index = 0; index < 256; index++) {
        const byte = index >> 3, bit = 1 << (index & 7);
        if (down[index]) view.setUint8(offset + byte, view.getUint8(offset + byte) | bit);
        if (pressed[index]) view.setUint8(offset + 32 + byte, view.getUint8(offset + 32 + byte) | bit);
        if (released[index]) view.setUint8(offset + 64 + byte, view.getUint8(offset + 64 + byte) | bit);
      }
      view.setUint8(offset + 96, active ? 1 : 0);
      view.setUint8(offset + 97, composing ? 1 : 0);
      view.setUint8(offset + 98, overflow ? 1 : 0);
      view.setUint8(offset + 99, events.length);
      view.setUint16(offset + 100, textBytes, true);
      let used = 0;
      for (const [index, event] of events.entries()) {
        const record = offset + 104 + index * 12;
        view.setUint8(record, event.kind);
        view.setUint8(record + 1, event.key ?? 0);
        view.setUint8(record + 2, event.repeat ? 1 : 0);
        view.setUint16(record + 4, used, true);
        view.setUint16(record + 6, event.bytes.length, true);
        view.setInt16(record + 8, -1, true);
        view.setInt16(record + 10, -1, true);
        for (const byte of event.bytes) view.setUint8(offset + 104 + events.length * 12 + used++, byte);
      }
      return 104 + events.length * 12 + textBytes;
    },
  };
}
