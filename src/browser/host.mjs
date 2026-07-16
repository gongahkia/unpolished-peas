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
  let logicalWidth = 0;
  let logicalHeight = 0;
  let primitivePipeline = null;
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

  function releasePrimitivePipeline(release) {
    if (!primitivePipeline) return;
    if (release && gl) {
      gl.deleteBuffer(primitivePipeline.buffer);
      gl.deleteProgram(primitivePipeline.program);
    }
    primitivePipeline = null;
  }

  function compileShader(type, source) {
    const shader = gl.createShader(type);
    if (!shader) return null;
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (gl.getShaderParameter(shader, gl.COMPILE_STATUS)) return shader;
    logger?.error?.(`unpolished-peas browser: WebGL shader compilation failed: ${gl.getShaderInfoLog(shader) ?? "unknown error"}`);
    gl.deleteShader(shader);
    return null;
  }

  function ensurePrimitivePipeline() {
    if (!gl || contextLost) return null;
    if (primitivePipeline) return primitivePipeline;
    const vertex = compileShader(gl.VERTEX_SHADER, `#version 300 es
      layout(location = 0) in vec2 in_position;
      layout(location = 1) in vec4 in_color;
      out vec4 out_color;
      void main() { gl_Position = vec4(in_position, 0.0, 1.0); out_color = in_color; }`);
    if (!vertex) return null;
    const fragment = compileShader(gl.FRAGMENT_SHADER, `#version 300 es
      precision mediump float;
      in vec4 out_color;
      out vec4 fragment_color;
      void main() { fragment_color = out_color; }`);
    if (!fragment) {
      gl.deleteShader(vertex);
      return null;
    }
    const program = gl.createProgram();
    if (!program) {
      gl.deleteShader(vertex);
      gl.deleteShader(fragment);
      return null;
    }
    gl.attachShader(program, vertex);
    gl.attachShader(program, fragment);
    gl.linkProgram(program);
    gl.deleteShader(vertex);
    gl.deleteShader(fragment);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      logger?.error?.(`unpolished-peas browser: WebGL program link failed: ${gl.getProgramInfoLog(program) ?? "unknown error"}`);
      gl.deleteProgram(program);
      return null;
    }
    const buffer = gl.createBuffer();
    if (!buffer) {
      gl.deleteProgram(program);
      return null;
    }
    primitivePipeline = {program, buffer};
    return primitivePipeline;
  }

  function colorFloats(color) {
    return [
      (color & 0xff) / 255,
      ((color >>> 8) & 0xff) / 255,
      ((color >>> 16) & 0xff) / 255,
      ((color >>> 24) & 0xff) / 255,
    ];
  }

  function vertex(x, y, color) {
    return [x * 2 / logicalWidth - 1, 1 - y * 2 / logicalHeight, ...color];
  }

  function quad(ax, ay, bx, by, cx, cy, dx, dy, color) {
    return [...vertex(ax, ay, color), ...vertex(bx, by, color), ...vertex(cx, cy, color), ...vertex(ax, ay, color), ...vertex(cx, cy, color), ...vertex(dx, dy, color)];
  }

  function drawVertices(vertices) {
    if (!gl) return Status.unavailable;
    if (contextLost || logicalWidth === 0 || logicalHeight === 0) return Status.rejected;
    const pipeline = ensurePrimitivePipeline();
    if (!pipeline) return Status.rejected;
    gl.useProgram(pipeline.program);
    gl.bindBuffer(gl.ARRAY_BUFFER, pipeline.buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(vertices), gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 24, 0);
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 4, gl.FLOAT, false, 24, 8);
    gl.enable(gl.BLEND);
    gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    gl.drawArrays(gl.TRIANGLES, 0, vertices.length / 6);
    return Status.ok;
  }

  function clear(color) {
    if (!gl) return Status.unavailable;
    if (contextLost) return Status.rejected;
    gl.clearColor(...colorFloats(color));
    gl.clear(gl.COLOR_BUFFER_BIT);
    return Status.ok;
  }

  function drawRect(x, y, width, height, color) {
    if (width <= 0 || height <= 0) return Status.ok;
    return drawVertices(quad(x, y, x + width, y, x + width, y + height, x, y + height, colorFloats(color)));
  }

  function drawLine(x0, y0, x1, y1, color) {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const length = Math.hypot(dx, dy);
    if (length === 0) return drawRect(x0 - 0.5, y0 - 0.5, 1, 1, color);
    const offsetX = -dy / length * 0.5;
    const offsetY = dx / length * 0.5;
    return drawVertices(quad(x0 + offsetX, y0 + offsetY, x1 + offsetX, y1 + offsetY, x1 - offsetX, y1 - offsetY, x0 - offsetX, y0 - offsetY, colorFloats(color)));
  }

  function drawCircle(x, y, radius, color) {
    if (radius <= 0) return Status.ok;
    const rgba = colorFloats(color);
    const vertices = [];
    for (let index = 0; index < 32; index += 1) {
      const a = index * Math.PI * 2 / 32;
      const b = (index + 1) * Math.PI * 2 / 32;
      vertices.push(...vertex(x, y, rgba), ...vertex(x + Math.cos(a) * radius, y + Math.sin(a) * radius, rgba), ...vertex(x + Math.cos(b) * radius, y + Math.sin(b) * radius, rgba));
    }
    return drawVertices(vertices);
  }

  function drawTriangle(ax, ay, bx, by, cx, cy, color) {
    const rgba = colorFloats(color);
    return drawVertices([...vertex(ax, ay, rgba), ...vertex(bx, by, rgba), ...vertex(cx, cy, rgba)]);
  }

  function present(mode) {
    if (!gl) return Status.unavailable;
    if (contextLost || mode > 2) return Status.rejected;
    gl.flush();
    return Status.ok;
  }

  function createContext(width, height) {
    if (!canvas || width === 0 || height === 0) return Status.invalidArgument;
    if (contextLost) return Status.rejected;
    canvas.width = width;
    canvas.height = height;
    logicalWidth = width;
    logicalHeight = height;
    gl ??= canvas.getContext("webgl2", {alpha: true, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: false});
    if (!gl) return Status.unavailable;
    if (gl.isContextLost?.()) {
      contextLost = true;
      removeAllResources(false);
      releasePrimitivePipeline(false);
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
    releasePrimitivePipeline(false);
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
      releasePrimitivePipeline(!contextLost);
      gl = null;
    },
    up_host_gl_resource_create: createResource,
    up_host_gl_resource_destroy: (kind, handle) => {
      const resource = resources.get(handle);
      if (!resource || resource.kind !== kind) return;
      removeResource(handle, true);
    },
    up_host_gl_context_lost: () => Number(contextLost || gl?.isContextLost?.()),
    up_host_gl_clear: clear,
    up_host_gl_draw_rect: drawRect,
    up_host_gl_draw_line: drawLine,
    up_host_gl_draw_circle: drawCircle,
    up_host_gl_draw_triangle: drawTriangle,
    up_host_gl_present: present,
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
      releasePrimitivePipeline(!contextLost);
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
