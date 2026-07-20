import {ResourceKind, Status} from "./host.mjs";

function requireStatus(value, operation) {
  if (value !== Status.ok) throw new Error(`browser workload failed: ${operation}`);
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

export function runWorkloadCatalog(runtime, host, catalog) {
  if (catalog?.schema_version !== 1 || catalog.workload_version !== "v1" || !Array.isArray(catalog.workloads) || catalog.workloads.length !== 6) throw new Error("browser workload catalog is invalid");
  let frames = 0;
  for (const workload of catalog.workloads) {
    requireStatus(runtime.up_browser_gl_context_create(workload.width, workload.height), "context_create");
    const assets = uploadAssets(runtime, host, catalog.assets.filter((asset) => workload.assets.includes(asset.id)));
    try {
      for (let frame = 0; frame < workload.warmup_frames + workload.frame_count; frame += 1) {
        for (const operation of workload.operations) runOperation(runtime, host, operation, assets);
        requireStatus(runtime.up_browser_present(0), "present");
        frames += 1;
      }
    } finally {
      for (const asset of assets.values()) runtime.up_browser_gl_resource_destroy(ResourceKind.texture, asset.handle);
    }
  }
  return {version: catalog.schema_version, workloads: catalog.workloads.length, frames};
}
