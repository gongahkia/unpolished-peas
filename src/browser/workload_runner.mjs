import {ResourceKind, Status} from "./host.mjs";

const workloadIds = ["primitive_fill", "sprite_batching", "alpha_blend", "clipping", "text", "mixed_frame"];
const metricIds = ["frame_time_ns", "command_count", "frame_allocation_events", "frame_allocated_bytes"];
export const browserTimerLimitations = Object.freeze([
  "frame_time_ns measures JavaScript submission around host calls; it does not wait for GPU completion.",
  "performance.now resolution and privacy quantization vary by browser and isolation settings.",
  "background throttling and compositor scheduling can change observed values; run in a foreground browser job.",
]);

function requireStatus(value, operation) {
  if (value !== Status.ok) throw new Error(`browser workload failed: ${operation}`);
}

function validateCatalog(catalog) {
  if (catalog?.schema_version !== 1 || catalog.workload_version !== "v1" || !Array.isArray(catalog.assets) || catalog.assets.length !== 1 || !Array.isArray(catalog.workloads) || catalog.workloads.length !== workloadIds.length) throw new Error("browser workload catalog is invalid");
  const [checker] = catalog.assets;
  if (checker?.id !== "checker_2x2" || checker.width !== 2 || checker.height !== 2 || !Array.isArray(checker.rgba) || checker.rgba.length !== 16) throw new Error("browser workload catalog asset is invalid");
  for (const id of workloadIds) if (catalog.workloads.filter((workload) => workload.id === id).length !== 1) throw new Error(`browser workload missing: ${id}`);
  for (const workload of catalog.workloads) {
    if (!Number.isInteger(workload.width) || !Number.isInteger(workload.height) || !Number.isInteger(workload.warmup_frames) || !Number.isInteger(workload.frame_count) || workload.width <= 0 || workload.height <= 0 || workload.warmup_frames <= 0 || workload.frame_count <= 0 || !Array.isArray(workload.assets) || !Array.isArray(workload.metrics) || workload.metrics.length !== metricIds.length) throw new Error(`browser workload invalid: ${workload.id}`);
    if (!workload.metrics.every((metric, index) => metric === metricIds[index]) || !workload.assets.every((asset) => asset === checker.id)) throw new Error(`browser workload schema invalid: ${workload.id}`);
  }
}

function batchPoint(operation, index) {
  return {
    x: operation.x + (index % operation.columns) * operation.step_x,
    y: operation.y + Math.floor(index / operation.columns) * operation.step_y,
  };
}

function uploadAssets(runtime, host, assets) {
  const output = new Map();
  let offset = 1024;
  for (const asset of assets) {
    if (!Array.isArray(asset.rgba) || asset.rgba.length !== asset.width * asset.height * 4 || offset > host.memory.buffer.byteLength - asset.rgba.length) throw new Error(`browser workload invalid asset: ${asset.id}`);
    new Uint8Array(host.memory.buffer, offset, asset.rgba.length).set(asset.rgba);
    const handle = runtime.up_browser_gl_resource_create(ResourceKind.texture, 0);
    if (handle === 0) throw new Error(`browser workload texture unavailable: ${asset.id}`);
    requireStatus(runtime.up_browser_texture_upload(handle, asset.width, asset.height, offset, asset.rgba.length, 0), "texture_upload");
    output.set(asset.id, {handle, width: asset.width, height: asset.height});
    offset += asset.rgba.length;
  }
  return output;
}

function runOperation(runtime, host, operation, assets) {
  switch (operation.op) {
    case "clear": return requireStatus(runtime.up_browser_clear(operation.color), operation.op);
    case "rect_batch":
      for (let index = 0; index < operation.count; index += 1) {
        const point = batchPoint(operation, index);
        requireStatus(runtime.up_browser_draw_rect(point.x, point.y, operation.w, operation.h, operation.color), operation.op);
      }
      return;
    case "sprite_batch": {
      const asset = assets.get(operation.asset);
      if (!asset) throw new Error(`browser workload missing asset: ${operation.asset}`);
      for (let index = 0; index < operation.count; index += 1) {
        const point = batchPoint(operation, index);
        requireStatus(runtime.up_browser_draw_sprite(asset.handle, 0, 0, asset.width, asset.height, point.x, point.y, operation.w, operation.h, 0xffffffff, 0), operation.op);
      }
      return;
    }
    case "text_batch": {
      const bytes = new TextEncoder().encode(operation.text);
      const offset = 4096;
      if (offset > host.memory.buffer.byteLength - bytes.length) throw new Error("browser workload text exceeds Wasm memory");
      new Uint8Array(host.memory.buffer, offset, bytes.length).set(bytes);
      for (let index = 0; index < operation.count; index += 1) {
        const point = batchPoint(operation, index);
        requireStatus(runtime.up_browser_draw_text(offset, bytes.length, point.x, point.y, operation.color), operation.op);
      }
      return;
    }
    case "push_clip": return requireStatus(runtime.up_browser_push_clip(operation.x, operation.y, operation.w, operation.h), operation.op);
    case "pop_clip": return requireStatus(runtime.up_browser_pop_clip(), operation.op);
    default: throw new Error(`browser workload unknown operation: ${operation.op}`);
  }
}

function operationCommandCount(operation) {
  switch (operation.op) {
    case "clear":
    case "push_clip":
    case "pop_clip": return 1;
    case "rect_batch":
    case "sprite_batch":
    case "text_batch": return operation.count;
    default: throw new Error(`browser workload unknown operation: ${operation.op}`);
  }
}

function runFrame(runtime, host, workload, assets) {
  let commands = 1;
  for (const operation of workload.operations) {
    runOperation(runtime, host, operation, assets);
    commands += operationCommandCount(operation);
  }
  requireStatus(runtime.up_browser_present(0), "present");
  return commands;
}

function validateBrowserTarget(browser, renderer) {
  if (!browser || !["chromium", "firefox", "webkit"].includes(browser.name) || typeof browser.version !== "string" || browser.version.length === 0) throw new Error("browser workload target is invalid");
  if (!["webgl2", "webgpu"].includes(renderer)) throw new Error("browser workload renderer is invalid");
}

export function browserVersion(browser, userAgent) {
  if (typeof userAgent !== "string") throw new Error("browser workload user agent is invalid");
  const match = ({chromium: /(?:Chromium|Chrome)\/([0-9.]+)/, firefox: /Firefox\/([0-9.]+)/, webkit: /Version\/([0-9.]+)/})[browser]?.exec(userAgent);
  if (!match) throw new Error(`browser workload version is unavailable: ${browser}`);
  return match[1];
}

export function unavailableBrowserWorkloadArtifact({browser, renderer, workloadVersion, diagnostic}) {
  validateBrowserTarget(browser, renderer);
  if (typeof workloadVersion !== "string" || workloadVersion.length === 0) throw new Error("browser workload version is invalid");
  return {schema_version: 1, status: "unavailable", target: {os: "browser", architecture: "browser", browser, renderer}, workload_version: workloadVersion, workloads: [], timer: {clock: "performance.now", unit: "nanoseconds", measurement: "cpu_submission", limitations: browserTimerLimitations}, diagnostics: {renderer_diagnostic: diagnostic ?? null}};
}

export function runWorkloadCatalog(runtime, host, catalog) {
  validateCatalog(catalog);
  let frames = 0;
  for (const workload of catalog.workloads) {
    requireStatus(runtime.up_browser_gl_context_create(workload.width, workload.height), "context_create");
    const assets = uploadAssets(runtime, host, catalog.assets.filter((asset) => workload.assets.includes(asset.id)));
    try {
      for (let frame = 0; frame < workload.warmup_frames + workload.frame_count; frame += 1) {
        runFrame(runtime, host, workload, assets);
        frames += 1;
      }
    } finally {
      for (const asset of assets.values()) runtime.up_browser_gl_resource_destroy(ResourceKind.texture, asset.handle);
    }
  }
  return {version: catalog.schema_version, workloads: catalog.workloads.length, frames};
}

export function benchmarkWorkloadCatalog(runtime, host, catalog, {browser, renderer, now = () => globalThis.performance?.now?.()} = {}) {
  validateCatalog(catalog);
  validateBrowserTarget(browser, renderer);
  if (typeof now !== "function") throw new Error("browser workload clock is invalid");
  const workloads = [];
  let frames = 0;
  for (const workload of catalog.workloads) {
    requireStatus(runtime.up_browser_gl_context_create(workload.width, workload.height), "context_create");
    const assets = uploadAssets(runtime, host, catalog.assets.filter((asset) => workload.assets.includes(asset.id)));
    try {
      for (let frame = 0; frame < workload.warmup_frames; frame += 1) runFrame(runtime, host, workload, assets);
      let elapsedNanoseconds = 0;
      let commandCount = 0;
      for (let frame = 0; frame < workload.frame_count; frame += 1) {
        const start = now();
        if (!Number.isFinite(start)) throw new Error("browser workload clock is unavailable");
        commandCount = runFrame(runtime, host, workload, assets);
        const end = now();
        if (!Number.isFinite(end) || end < start) throw new Error("browser workload clock is invalid");
        elapsedNanoseconds += Math.round((end - start) * 1_000_000);
      }
      workloads.push({id: workload.id, resolution: {width: workload.width, height: workload.height}, warmup_frames: workload.warmup_frames, sample_count: workload.frame_count, metrics: {frame_time_ns: Math.round(elapsedNanoseconds / workload.frame_count), command_count: commandCount, frame_allocation_events: null, frame_allocated_bytes: null}, metric_availability: {frame_time_ns: "measured_cpu_submission", command_count: "measured", frame_allocation_events: "unavailable", frame_allocated_bytes: "unavailable"}});
      frames += workload.warmup_frames + workload.frame_count;
    } finally {
      for (const asset of assets.values()) runtime.up_browser_gl_resource_destroy(ResourceKind.texture, asset.handle);
    }
  }
  return {schema_version: 1, status: "ok", target: {os: "browser", architecture: "browser", browser, renderer}, workload_version: catalog.workload_version, workloads, timer: {clock: "performance.now", unit: "nanoseconds", measurement: "cpu_submission", limitations: browserTimerLimitations}, diagnostics: {total_frames: frames}};
}
