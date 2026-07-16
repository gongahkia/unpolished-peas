export const StorageStatus = Object.freeze({ok: 0, invalidArgument: -1, unavailable: -2, rejected: -3});

function decodeUtf8(bytes) {
  try {
    return new TextDecoder("utf-8", {fatal: true}).decode(bytes);
  } catch {
    return null;
  }
}

function encodeBase64(bytes) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let value = "";
  for (let index = 0; index < bytes.length; index += 3) {
    const first = bytes[index];
    const second = bytes[index + 1] ?? 0;
    const third = bytes[index + 2] ?? 0;
    value += alphabet[first >>> 2];
    value += alphabet[((first & 3) << 4) | (second >>> 4)];
    value += index + 1 < bytes.length ? alphabet[((second & 15) << 2) | (third >>> 6)] : "=";
    value += index + 2 < bytes.length ? alphabet[third & 63] : "=";
  }
  return value;
}

function decodeBase64(value) {
  if (typeof value !== "string" || value.length % 4 !== 0) return null;
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const bytes = [];
  for (let index = 0; index < value.length; index += 4) {
    const first = alphabet.indexOf(value[index]);
    const second = alphabet.indexOf(value[index + 1]);
    const third = value[index + 2] === "=" ? 0 : alphabet.indexOf(value[index + 2]);
    const fourth = value[index + 3] === "=" ? 0 : alphabet.indexOf(value[index + 3]);
    if (first < 0 || second < 0 || third < 0 || fourth < 0 || value[index + 2] === "=" && value[index + 3] !== "=" || (value[index + 2] === "=" || value[index + 3] === "=") && index + 4 !== value.length) return null;
    bytes.push((first << 2) | (second >>> 4));
    if (value[index + 2] !== "=") bytes.push(((second & 15) << 4) | (third >>> 2));
    if (value[index + 3] !== "=") bytes.push(((third & 3) << 6) | fourth);
  }
  return new Uint8Array(bytes);
}

export function createBrowserStorage({storage, namespace = "unpolished-peas:v1", maxValueBytes = 1024 * 1024} = {}) {
  let phase = "ready";
  let lastError = null;
  if (!storage) phase = "unavailable";
  else try {
    void storage.length;
  } catch {
    phase = "failed";
    lastError = "initialization_failed";
  }

  function keyFromMemory(memory, source, byteLength) {
    if (!Number.isInteger(source) || !Number.isInteger(byteLength) || source < 0 || byteLength <= 0 || byteLength > 256 || source > memory.buffer.byteLength - byteLength) return null;
    const key = decodeUtf8(new Uint8Array(memory.buffer, source, byteLength));
    if (!key || key.includes("\0")) return null;
    return `${namespace}/${key}`;
  }

  function fail(error) {
    phase = "failed";
    lastError = error;
    return StorageStatus.rejected;
  }

  function availability() {
    return phase === "ready" ? StorageStatus.ok : phase === "unavailable" ? StorageStatus.unavailable : StorageStatus.rejected;
  }

  function write(memory, keySource, keyLength, source, byteLength) {
    const state = availability();
    if (state !== StorageStatus.ok) return state;
    const key = keyFromMemory(memory, keySource, keyLength);
    if (!key || !Number.isInteger(source) || !Number.isInteger(byteLength) || source < 0 || byteLength < 0 || byteLength > maxValueBytes || source > memory.buffer.byteLength - byteLength) return StorageStatus.invalidArgument;
    try {
      const value = encodeBase64(new Uint8Array(memory.buffer, source, byteLength));
      storage.setItem(key, `UPST1:${value}`);
      return StorageStatus.ok;
    } catch {
      return fail("write_failed");
    }
  }

  function read(memory, keySource, keyLength, destination, capacity) {
    const state = availability();
    if (state !== StorageStatus.ok) return state;
    const key = keyFromMemory(memory, keySource, keyLength);
    if (!key || !Number.isInteger(destination) || !Number.isInteger(capacity) || destination < 0 || capacity < 0) return StorageStatus.invalidArgument;
    try {
      const record = storage.getItem(key);
      if (record === null) return 0;
      if (!record.startsWith("UPST1:")) return fail("invalid_record");
      const value = decodeBase64(record.slice(6));
      if (!value || value.length > maxValueBytes) return fail("invalid_record");
      if (capacity < value.length) return value.length;
      if (destination > memory.buffer.byteLength - value.length) return StorageStatus.invalidArgument;
      new Uint8Array(memory.buffer, destination, value.length).set(value);
      return value.length;
    } catch {
      return fail("read_failed");
    }
  }

  function remove(memory, keySource, keyLength) {
    const state = availability();
    if (state !== StorageStatus.ok) return state;
    const key = keyFromMemory(memory, keySource, keyLength);
    if (!key) return StorageStatus.invalidArgument;
    try {
      storage.removeItem(key);
      return StorageStatus.ok;
    } catch {
      return fail("remove_failed");
    }
  }

  return {
    read,
    write,
    remove,
    diagnostic: () => ({phase, namespace, maxValueBytes, lastError}),
    key: (name) => `${namespace}/${name}`,
  };
}
