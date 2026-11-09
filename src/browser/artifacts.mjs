function decodeUtf8(bytes) {
  try {
    return new TextDecoder("utf-8", {fatal: true}).decode(bytes);
  } catch {
    return null;
  }
}

export const artifactLimits = Object.freeze({messages: 128, traces: 512, commands: 256, messageBytes: 1024, recordBytes: 4096, screenshotBytes: 16 * 1024 * 1024});
const encoder = new TextEncoder();

const levels = Object.freeze(["trace", "debug", "info", "warn", "err", "fatal"]);
const categories = Object.freeze(["engine", "assets", "render", "input", "audio", "storage", "diagnostics", "platform"]);

export function createBrowserArtifacts({canvas, limits = artifactLimits, logging = null, onEvent = null, clock = () => globalThis.performance?.now?.() ?? Date.now()} = {}) {
  for (const name of Object.keys(artifactLimits)) {
    if (!Number.isSafeInteger(limits[name]) || limits[name] < 1 || limits[name] > artifactLimits[name]) throw new Error("invalid_artifact_limits:" + name);
  }
  limits = Object.freeze(Object.fromEntries(Object.keys(artifactLimits).map((name) => [name, limits[name]])));
  const diagnostics = [];
  const trace = [];
  const commands = [];
  const counts = Object.fromEntries(["diagnostics", "trace", "commands", "screenshot"].map((name) => [name, {dropped: 0, rejected: 0}]));

  // Structured collection is opt-in. No clock read or event serialization
  // occurs in log() while disabled; legacy explicitly requested artifacts stay available.
  let eventLog = null;
  if (logging && logging.level !== "off") {
    const minimum = logging.level ?? "info";
    const selected = logging.categories ?? categories;
    if (!levels.includes(minimum) || !Array.isArray(selected) || selected.some((name) => !categories.includes(name))) throw new Error("invalid_logging_filter");
    const id = logging.sessionId ?? Math.floor(Math.random() * Number.MAX_SAFE_INTEGER);
    if (!Number.isSafeInteger(id) || id < 1) throw new Error("invalid_logging_session");
    eventLog = {minimum, selected: [...selected], session: id, started: clock(), frame: 0, records: [], bytes: 0, dropped: 0, truncated: 0, rejected: 0, incidents: [], failure: 0, droppedIncidents: 0, sinkErrors: 0};
  }

  function boundedText(value) {
    const text = String(value);
    const bytes = new Uint8Array(limits.messageBytes);
    const {read, written} = encoder.encodeInto(text, bytes);
    if (read !== text.length) eventLog.truncated += 1;
    return new TextDecoder().decode(bytes.subarray(0, written));
  }

  function log(level, category, message, fields = {}) {
    if (!eventLog) return false;
    if (!levels.includes(level) || !categories.includes(category)) { eventLog.rejected += 1; return false; }
    if (levels.indexOf(level) < levels.indexOf(eventLog.minimum) || !eventLog.selected.includes(category)) return false;
    try {
      const ownedFields = Object.create(null);
      let count = 0;
      for (const key of Object.keys(fields)) {
        if (count === 16) { eventLog.truncated += 1; break; }
        const value = fields[key];
        if (!/^[A-Za-z0-9_.-]{1,64}$/.test(key) || !(typeof value === "string" || typeof value === "boolean" || Number.isSafeInteger(value))) {
          eventLog.rejected += 1;
          return false;
        }
        ownedFields[key] = typeof value === "string" ? boundedText(value) : value;
        count += 1;
      }
      const event = {version: 1, timestamp_ns: Math.min(Number.MAX_SAFE_INTEGER, Math.max(0, Math.trunc((clock() - eventLog.started) * 1e6))), session_id: eventLog.session, frame_id: eventLog.frame, level, category, message: boundedText(message), fields: ownedFields};
      const line = JSON.stringify(event) + "\n";
      const bytes = encoder.encode(line).length;
      while (eventLog.records.length === 128 || eventLog.bytes + bytes > 256 * 1024) {
        eventLog.bytes -= eventLog.records.shift().bytes;
        eventLog.dropped += 1;
      }
      eventLog.records.push({line, bytes}); eventLog.bytes += bytes;
      try { onEvent?.(event); } catch { eventLog.sinkErrors += 1; }
      return true;
    } catch {
      eventLog.rejected += 1;
      return false;
    }
  }

  function failure(phase, error, operation = phase) {
    if (!eventLog) return null;
    try {
    const details = {phase: boundedText(phase), error: boundedText(error), operation: boundedText(operation)};
    log("err", "engine", "runtime failure", details);
    const captured = captureFrame();
    const incident = {
      version: 1, session_id: eventLog.session, failure_id: ++eventLog.failure, frame_id: eventLog.frame,
      ...details, renderer: rendererDiagnostic,
      events_jsonl: eventLog.records.map(({line}) => line).join(""),
      dropped_events: eventLog.dropped, trace: trace.slice(), commands: commands.slice(), screenshot: captured,
    };
    if (eventLog.incidents.length === 4) { eventLog.incidents.shift(); eventLog.droppedIncidents += 1; }
    eventLog.incidents.push(incident);
    return "incident-" + incident.session_id + "-" + incident.failure_id + ".json";
    } catch {
      eventLog.rejected += 1;
      return null;
    }
  }

  function append(name, target, value, capacity) {
    if (target.length === capacity) { target.shift(); counts[name].dropped += 1; }
    target.push(value);
  }

  function record(name, target, value, capacity) {
    try {
      // Retain a bounded owned snapshot, never a caller's mutable object.
      const encoded = JSON.stringify(value);
      if (typeof encoded !== "string" || encoder.encode(encoded).length > limits.recordBytes) {
        counts[name].rejected += 1;
        return false;
      }
      append(name, target, JSON.parse(encoded), capacity);
      return true;
    } catch {
      counts[name].rejected += 1;
      return false;
    }
  }
  let screenshot = null;
  let rendererDiagnostic = null;

  function captureFrame() {
    if (!canvas?.toDataURL) return null;
    try {
      const value = canvas.toDataURL("image/png");
      if (typeof value !== "string" || !/^data:image\/png(?:;[^,]*)?,.+$/.test(value) || value.length > limits.screenshotBytes) {
        counts.screenshot.rejected += 1;
        return null;
      }
      screenshot = value;
      return screenshot;
    } catch {
      counts.screenshot.rejected += 1;
      return null;
    }
  }

  function emit(memory, source, byteLength) {
    if (!Number.isInteger(source) || !Number.isInteger(byteLength) || source < 0 || byteLength < 0 || source > memory.buffer.byteLength - byteLength) { counts.diagnostics.rejected += 1; return false; }
    if (byteLength > limits.messageBytes) { counts.diagnostics.rejected += 1; return false; }
    const message = decodeUtf8(new Uint8Array(memory.buffer, source, byteLength));
    if (message === null) { counts.diagnostics.rejected += 1; return false; }
    append("diagnostics", diagnostics, message, limits.messages);
    if (eventLog) {
      let structured = null;
      try { structured = JSON.parse(message); } catch {}
      if (structured?.kind === "protocol_failure" && typeof structured.phase === "string" && typeof structured.error === "string") failure(structured.phase, structured.error, structured.operation ?? structured.phase);
      else log("info", "diagnostics", message);
    }
    return true;
  }

  function snapshot() {
    const values = [
      {name: "diagnostics.json", type: "application/json", data: JSON.stringify({version: 1, messages: diagnostics})},
      {name: "trace.json", type: "application/json", data: JSON.stringify({displayTimeUnit: "ms", traceEvents: trace})},
      {name: "commands.json", type: "application/json", data: JSON.stringify({version: 1, commands})},
    ];
    const eventSummary = eventLog ? {enabled: true, event_schema_version: 1, session_id: eventLog.session, timestamp_unit: "nanoseconds", timestamp_origin: "session_start", min_level: eventLog.minimum, categories: eventLog.selected, max_events: 128, max_bytes: 256 * 1024, retained_events: eventLog.records.length, retained_bytes: eventLog.bytes, dropped_events: eventLog.dropped, truncated_values: eventLog.truncated, rejected_events: eventLog.rejected, sink_errors: eventLog.sinkErrors, max_incidents: 4, dropped_incidents: eventLog.droppedIncidents} : {enabled: false};
    values.push({name: "logging.json", type: "application/json", data: JSON.stringify({version: 1, limits, retention: counts, events: eventSummary})});
    if (eventLog) {
      values.push({name: "events.jsonl", type: "application/x-ndjson", data: eventLog.records.map(({line}) => line).join("")});
      for (const incident of eventLog.incidents) values.push({name: "incident-" + incident.session_id + "-" + incident.failure_id + ".json", type: "application/json", data: JSON.stringify(incident)});
    }
    if (rendererDiagnostic) values.unshift({name: "renderer-diagnostics.json", type: "application/json", data: JSON.stringify(rendererDiagnostic)});
    if (screenshot) values.unshift({name: "screenshot.png", type: "image/png", data: screenshot});
    return values;
  }

  return {
    captureFrame,
    emit,
    log,
    failure,
    logEnabled: Boolean(eventLog),
    beginFrame: () => { if (eventLog) eventLog.frame = Math.min(Number.MAX_SAFE_INTEGER, eventLog.frame + 1); },
    recordTrace: (event) => record("trace", trace, event, limits.traces),
    recordCommand: (command) => record("commands", commands, command, limits.commands),
    setRendererDiagnostic: (value) => {
      try {
        const encoded = JSON.stringify(value);
        if (typeof encoded !== "string" || encoder.encode(encoded).length > limits.recordBytes) return false;
        rendererDiagnostic = JSON.parse(encoded);
        return true;
      } catch { return false; }
    },
    snapshot,
  };
}
