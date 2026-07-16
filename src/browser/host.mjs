export const AbiVersion = 1;

export const ResourceKind = Object.freeze({
  buffer: 0,
  texture: 1,
  program: 2,
  framebuffer: 3,
});

export const Status = Object.freeze({
  ok: 0,
  invalidArgument: -1,
  unavailable: -2,
  rejected: -3,
});

export function createBrowserHost({canvas, console: logger = globalThis.console} = {}) {
  let gl = null;
  let contextLost = false;
  let nextHandle = 1;
  const resources = new Map();

  function removeResource(handle, release) {
    const resource = resources.get(handle);
    if (!resource) return;
    if (release && gl) {
      switch (resource.kind) {
        case ResourceKind.buffer: gl.deleteBuffer(resource.value); break;
        case ResourceKind.texture: gl.deleteTexture(resource.value); break;
        case ResourceKind.program: gl.deleteProgram(resource.value); break;
        case ResourceKind.framebuffer: gl.deleteFramebuffer(resource.value); break;
      }
    }
    resources.delete(handle);
  }

  function removeAllResources(release) {
    for (const handle of [...resources.keys()]) removeResource(handle, release);
  }

  function createContext(width, height) {
    if (!canvas || width === 0 || height === 0) return Status.invalidArgument;
    if (contextLost) return Status.rejected;
    canvas.width = width;
    canvas.height = height;
    gl ??= canvas.getContext("webgl2", {alpha: true, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: false});
    if (!gl) return Status.unavailable;
    if (gl.isContextLost?.()) {
      contextLost = true;
      removeAllResources(false);
      return Status.rejected;
    }
    return Status.ok;
  }

  function createResource(kind, byteLength) {
    if (!gl || contextLost || !Number.isInteger(byteLength) || byteLength < 0) return 0;
    let value = null;
    switch (kind) {
      case ResourceKind.buffer:
        value = gl.createBuffer();
        if (value) {
          gl.bindBuffer(gl.ARRAY_BUFFER, value);
          gl.bufferData(gl.ARRAY_BUFFER, byteLength, gl.DYNAMIC_DRAW);
        }
        break;
      case ResourceKind.texture:
        value = gl.createTexture();
        if (value) {
          gl.bindTexture(gl.TEXTURE_2D, value);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        }
        break;
      case ResourceKind.program:
        value = gl.createProgram();
        break;
      case ResourceKind.framebuffer:
        value = gl.createFramebuffer();
        break;
      default:
        return 0;
    }
    if (!value) return 0;
    const handle = nextHandle;
    nextHandle += 1;
    resources.set(handle, {kind, value});
    return handle;
  }

  function onContextLost(event) {
    event.preventDefault();
    contextLost = true;
    removeAllResources(false);
  }

  function onContextRestored() {
    contextLost = false;
    gl = null;
  }

  canvas?.addEventListener("webglcontextlost", onContextLost);
  canvas?.addEventListener("webglcontextrestored", onContextRestored);

  const env = {
    up_host_schedule_frame: () => 0,
    up_host_cancel_frame: () => {},
    up_host_gl_context_create: createContext,
    up_host_gl_context_destroy: () => {
      removeAllResources(!contextLost);
      gl = null;
    },
    up_host_gl_resource_create: createResource,
    up_host_gl_resource_destroy: (kind, handle) => {
      const resource = resources.get(handle);
      if (!resource || resource.kind !== kind) return;
      removeResource(handle, true);
    },
    up_host_gl_context_lost: () => Number(contextLost || gl?.isContextLost?.()),
    up_host_input_poll: () => 0,
    up_host_input_read: () => 0,
    up_host_audio_state: () => Status.unavailable,
    up_host_audio_submit: () => Status.unavailable,
    up_host_storage_read: () => Status.unavailable,
    up_host_storage_write: () => Status.unavailable,
    up_host_storage_remove: () => Status.unavailable,
    up_host_diagnostic_emit: () => {},
    up_host_teardown: () => {
      removeAllResources(!contextLost);
      canvas?.removeEventListener("webglcontextlost", onContextLost);
      canvas?.removeEventListener("webglcontextrestored", onContextRestored);
      gl = null;
    },
  };

  return {
    abiVersion: AbiVersion,
    imports: {env},
    resourceCount: () => resources.size,
    context: () => gl,
    diagnostic: (message) => logger?.error?.(`unpolished-peas browser: ${message}`),
  };
}
