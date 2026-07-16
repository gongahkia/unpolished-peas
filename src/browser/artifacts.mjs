function decodeUtf8(bytes) {
  try {
    return new TextDecoder("utf-8", {fatal: true}).decode(bytes);
  } catch {
    return null;
  }
}

export function createBrowserArtifacts({canvas} = {}) {
  const diagnostics = [];
  const trace = [];
  const commands = [];
  let screenshot = null;

  function captureFrame() {
    if (!canvas?.toDataURL) return null;
    try {
      screenshot = canvas.toDataURL("image/png");
      return screenshot;
    } catch {
      return null;
    }
  }

  function emit(memory, source, byteLength) {
    if (!Number.isInteger(source) || !Number.isInteger(byteLength) || source < 0 || byteLength < 0 || source > memory.buffer.byteLength - byteLength) return false;
    const message = decodeUtf8(new Uint8Array(memory.buffer, source, byteLength));
    if (message === null) return false;
    diagnostics.push(message);
    return true;
  }

  function snapshot() {
    const values = [
      {name: "diagnostics.json", type: "application/json", data: JSON.stringify({version: 1, messages: diagnostics})},
      {name: "trace.json", type: "application/json", data: JSON.stringify({displayTimeUnit: "ms", traceEvents: trace})},
      {name: "commands.json", type: "application/json", data: JSON.stringify({version: 1, commands})},
    ];
    if (screenshot) values.unshift({name: "screenshot.png", type: "image/png", data: screenshot});
    return values;
  }

  return {
    captureFrame,
    emit,
    recordTrace: (event) => { trace.push(event); },
    recordCommand: (command) => { commands.push(command); },
    snapshot,
  };
}
