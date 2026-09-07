/* global AudioContext, Blob, ImageData, TextDecoder, URL, Worker, atob, document, localStorage, navigator, requestAnimationFrame */

// Embedded PX-240C revision-1 standalone player. Made by @gongahkia.
(() => {
  'use strict';

  const payload = globalThis.__PX240C_CARTRIDGE__;
  const palette = [
    '#17141f',
    '#292532',
    '#403946',
    '#5d5054',
    '#806a63',
    '#aa8b74',
    '#d5b992',
    '#f4e5bd',
    '#5b2938',
    '#8b3c47',
    '#bf5558',
    '#ed7b69',
    '#5a3928',
    '#89572e',
    '#c18436',
    '#e7bd50',
    '#263c32',
    '#345f46',
    '#4b8b58',
    '#7fbd68',
    '#203b47',
    '#2e6571',
    '#43969a',
    '#75cbc0',
    '#243451',
    '#345581',
    '#4b7db3',
    '#73a9d1',
    '#3e3154',
    '#654777',
    '#936397',
    '#c38aae',
  ];
  const rgba = palette.flatMap((hex) =>
    [1, 3, 5].map((offset) => Number.parseInt(hex.slice(offset, offset + 2), 16)).concat(255),
  );
  const decode = (value) => Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
  const text = (path) => new TextDecoder().decode(decode(payload.files[path]));
  const assets = new Map();
  for (const [name, declaration] of Object.entries(payload.manifest.assets)) {
    assets.set(name, {
      ...JSON.parse(text(declaration.path)),
      name,
      declaredKind: declaration.kind,
    });
  }
  const display = payload.manifest.display ? JSON.parse(text(payload.manifest.display)) : null;
  const sourceEntries = Object.keys(payload.files)
    .filter((path) => path.startsWith('source/'))
    .sort();
  const canvas = document.querySelector('#screen');
  const context = canvas.getContext('2d', { alpha: false });
  const status = document.querySelector('#status');
  const soundButton = document.querySelector('#sound');
  const sourceButton = document.querySelector('#source');
  const inspector = document.querySelector('#inspector');
  const sourceSelect = document.querySelector('#source-file');
  const sourceView = document.querySelector('#source-view');
  document.querySelector('#title').textContent = payload.manifest.title;
  document.querySelector('#author').textContent = `AUTHOR: ${payload.manifest.author}`;

  for (const path of sourceEntries) {
    const option = document.createElement('option');
    option.value = path;
    option.textContent = path.slice(7);
    sourceSelect.append(option);
  }
  const showSource = () => {
    const path = sourceSelect.value || sourceEntries[0];
    sourceView.textContent = path ? text(path) : 'NO SOURCE';
  };
  sourceSelect.addEventListener('change', showSource);
  sourceButton.addEventListener('click', () => {
    inspector.hidden = !inspector.hidden;
    sourceButton.textContent = inspector.hidden ? 'SOURCE' : 'PLAY';
    showSource();
  });
  document.querySelector('#close-source').addEventListener('click', () => {
    inspector.hidden = true;
    sourceButton.textContent = 'SOURCE';
  });

  const buttons = ['up', 'down', 'left', 'right', 'a', 'b', 'x', 'y', 'l', 'r', 'start', 'menu'];
  const bindings = {
    ArrowUp: [0, 'up'],
    ArrowDown: [0, 'down'],
    ArrowLeft: [0, 'left'],
    ArrowRight: [0, 'right'],
    KeyZ: [0, 'a'],
    KeyX: [0, 'b'],
    KeyA: [0, 'x'],
    KeyS: [0, 'y'],
    KeyQ: [0, 'l'],
    KeyW: [0, 'r'],
    Enter: [0, 'start'],
    Escape: [0, 'menu'],
    KeyI: [1, 'up'],
    KeyK: [1, 'down'],
    KeyJ: [1, 'left'],
    KeyL: [1, 'right'],
    KeyF: [1, 'a'],
    KeyG: [1, 'b'],
    KeyR: [1, 'x'],
    KeyT: [1, 'y'],
    KeyV: [1, 'l'],
    KeyB: [1, 'r'],
    Digit1: [1, 'start'],
    Backquote: [1, 'menu'],
  };
  const held = new Set();
  globalThis.addEventListener('keydown', (event) => {
    if (bindings[event.code]) {
      event.preventDefault();
      held.add(event.code);
    }
  });
  globalThis.addEventListener('keyup', (event) => held.delete(event.code));
  globalThis.addEventListener('blur', () => held.clear());
  const pointer = { x: 0, y: 0, primary: false, secondary: false, inside: false };
  const updatePointer = (event) => {
    const bounds = canvas.getBoundingClientRect();
    pointer.x = Math.max(
      0,
      Math.min(239, Math.floor(((event.clientX - bounds.left) * 240) / bounds.width)),
    );
    pointer.y = Math.max(
      0,
      Math.min(143, Math.floor(((event.clientY - bounds.top) * 144) / bounds.height)),
    );
    pointer.inside = event.type !== 'pointerleave' && event.type !== 'pointercancel';
    pointer.primary = (event.buttons & 1) !== 0;
    pointer.secondary = (event.buttons & 2) !== 0;
  };
  for (const name of [
    'pointerenter',
    'pointermove',
    'pointerdown',
    'pointerup',
    'pointerleave',
    'pointercancel',
  ])
    canvas.addEventListener(name, (event) => {
      event.preventDefault();
      updatePointer(event);
    });
  canvas.addEventListener('contextmenu', (event) => event.preventDefault());
  const input = () => {
    const controllers = Array.from({ length: 4 }, () => ({
      buttons: Object.fromEntries(buttons.map((name) => [name, false])),
    }));
    for (const code of held) {
      const binding = bindings[code];
      if (binding) controllers[binding[0]].buttons[binding[1]] = true;
    }
    for (const gamepad of navigator.getGamepads?.() ?? []) {
      if (!gamepad || gamepad.index > 3) continue;
      const map = {
        up: 12,
        down: 13,
        left: 14,
        right: 15,
        a: 0,
        b: 1,
        x: 2,
        y: 3,
        l: 4,
        r: 5,
        start: 9,
        menu: 8,
      };
      for (const [name, index] of Object.entries(map))
        controllers[gamepad.index].buttons[name] ||= gamepad.buttons[index]?.pressed ?? false;
    }
    return { controllers, pointer: { ...pointer } };
  };

  function workerMain() {
    'use strict';
    let cartridge;
    let frame = 0;
    let updateRate = 60;
    let work = 0;
    let previousInput;
    let currentInput;
    let rng = 0x240c1999;
    let maps = {};
    let save = {};
    let saveWrites = [];
    let draw = [];
    let audio = [];
    let phase = 'start';
    let rasterLine;
    const span = { start: 0, end: 0 };
    const fault = (code, message, sourceSpan = span) => {
      const error = new Error(message);
      error.code = code;
      error.sourceSpan = sourceSpan;
      throw error;
    };
    const random = () => {
      rng ^= rng << 13;
      rng ^= rng >>> 17;
      rng ^= rng << 5;
      rng >>>= 0;
      return rng;
    };
    const pressed = (port, name, input) => input?.controllers?.[port]?.buttons?.[name] ?? false;
    const charge = (units, sourceSpan) => {
      work += units;
      if (work > 50000) fault('PX9001', 'frame exceeded 50000 work units', sourceSpan);
    };
    const consoleCost = (name, args) => {
      const integer = (index) => (Number.isSafeInteger(args[index]) ? args[index] : 0);
      if (name === 'clear') return Math.ceil((240 * 144) / 32);
      if (name === 'pixel') return 1;
      if (name === 'line')
        return Math.max(Math.abs(integer(2) - integer(0)), Math.abs(integer(3) - integer(1))) + 1;
      if (name === 'rect') return Math.max(1, 2 * Math.abs(integer(2)) + 2 * Math.abs(integer(3)));
      if (name === 'rect_fill')
        return Math.max(1, Math.ceil((Math.abs(integer(2)) * Math.abs(integer(3))) / 4));
      if (name === 'circle') return Math.max(1, Math.abs(integer(2)) * 8);
      if (name === 'circle_fill')
        return Math.max(1, Math.ceil((Math.abs(integer(2)) ** 2 * 3) / 4));
      if (name === 'triangle') {
        const area = Math.abs(
          (integer(2) - integer(0)) * (integer(5) - integer(1)) -
            (integer(4) - integer(0)) * (integer(3) - integer(1)),
        );
        return Math.max(1, Math.ceil(area / 8));
      }
      if (name === 'sprite' || name === 'animation') return 32;
      if (name === 'sprite_xform') return Math.max(32, 32 * Math.abs(integer(3)) ** 2);
      if (name === 'map') return 128;
      if (name === 'print')
        return Math.max(1, (typeof args[0] === 'string' ? args[0].length : 0) * 6);
      if (name === 'sfx' || name === 'music' || name === 'music_stop') return 8;
      return 1;
    };
    const api = {
      work(units, sourceSpan) {
        charge(units, sourceSpan);
      },
      fault,
      call(name, args, sourceSpan) {
        charge(consoleCost(name, args), sourceSpan);
        if (phase === 'raster' && name !== 'pal' && name !== 'raster_scroll')
          fault(
            'PX9011',
            `console API call '${name}' is not valid in the raster callback`,
            sourceSpan,
          );
        if (name === 'raster_scroll' && phase !== 'raster')
          fault('PX9011', 'raster_scroll is only valid in the raster callback', sourceSpan);
        if (name === 'rng_num') return random() / 4294967296;
        if (name === 'rng_int') {
          const [minimum, maximum] = args;
          if (
            !Number.isSafeInteger(minimum) ||
            !Number.isSafeInteger(maximum) ||
            maximum <= minimum
          )
            fault('PX9007', 'invalid RNG bounds', sourceSpan);
          const range = maximum - minimum;
          const limit = 4294967296 - (4294967296 % range);
          let sample;
          do sample = random();
          while (sample >= limit);
          return minimum + (sample % range);
        }
        if (name === 'Vec2') return { x: args[0], y: args[1] };
        if (name === 'Rect') return { x: args[0], y: args[1], w: args[2], h: args[3] };
        if (name === 'dither') {
          const matrix = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
          const level = Math.max(0, Math.min(16, args[4]));
          return matrix[(((args[1] % 4) + 4) % 4) * 4 + (((args[0] % 4) + 4) % 4)] < level
            ? args[3]
            : args[2];
        }
        if (name === 'btn') return pressed(args[0], args[1], currentInput);
        if (name === 'btnp')
          return (
            pressed(args[0], args[1], currentInput) && !pressed(args[0], args[1], previousInput)
          );
        if (name === 'pointer_x') return currentInput?.pointer?.x ?? 0;
        if (name === 'pointer_y') return currentInput?.pointer?.y ?? 0;
        if (name === 'pointer_inside') return currentInput?.pointer?.inside ?? false;
        if (name === 'pointer_primary' || name === 'pointer_secondary') {
          const button = name === 'pointer_primary' ? 'primary' : 'secondary';
          return (
            (currentInput?.pointer?.[button] ?? false) &&
            !(previousInput?.pointer?.[button] ?? false)
          );
        }
        if (name === 'save_get_int') return Object.hasOwn(save, args[0]) ? save[args[0]] : args[1];
        if (name === 'save_set_int') {
          save[args[0]] = args[1];
          saveWrites.push({ key: args[0], value: args[1] });
          return;
        }
        if (name === 'map_cell' || name === 'map_flag') {
          const map = maps[args[0]?.name];
          const layer = map?.layers?.[args[1]];
          const x = args[2],
            y = args[3];
          if (!layer || x < 0 || y < 0 || x >= layer.width || y >= layer.height)
            return name === 'map_cell' ? -1 : false;
          const tile = layer.cells[y * layer.width + x];
          return name === 'map_cell' ? tile : ((layer.flags[tile] ?? 0) & (1 << args[4])) !== 0;
        }
        const command = {
          name,
          arguments: globalThis.structuredClone(args),
          sourceSpan,
          ...(rasterLine === undefined ? {} : { rasterLine }),
        };
        if (['sfx', 'music', 'music_stop'].includes(name)) audio.push(command);
        else {
          if (draw.length >= 4096) fault('PX9010', 'draw-command ceiling exceeded', sourceSpan);
          draw.push(command);
        }
      },
    };
    globalThis.onmessage = async (event) => {
      const request = event.data;
      try {
        if (request.type === 'load') {
          updateRate = request.updateRate;
          maps = request.maps;
          save = request.save;
          const loaded = await import(request.moduleUrl);
          cartridge = loaded.default(api);
          phase = 'start';
          rasterLine = undefined;
          cartridge.start();
          for (const name of [
            'Date',
            'fetch',
            'WebSocket',
            'XMLHttpRequest',
            'indexedDB',
            'crypto',
            'eval',
            'Function',
          ]) {
            try {
              globalThis[name] = undefined;
            } catch {
              /* immutable host capability */
            }
          }
          try {
            Math.random = undefined;
          } catch {
            /* immutable host capability */
          }
          globalThis.postMessage({ id: request.id, type: 'loaded' });
          return;
        }
        if (request.type === 'frame') {
          previousInput = currentInput;
          currentInput = request.input;
          work = 0;
          draw = [];
          audio = [];
          saveWrites = [];
          rasterLine = undefined;
          if (updateRate === 60 || frame % 2 === 0) {
            phase = 'update';
            cartridge.update();
          }
          phase = 'draw';
          cartridge.draw();
          phase = 'raster';
          for (let line = 0; line < 144; line++) {
            rasterLine = line;
            cartridge.raster(line);
          }
          rasterLine = undefined;
          globalThis.postMessage({
            id: request.id,
            type: 'frame',
            frame: frame++,
            work,
            draw,
            audio,
            saveWrites,
          });
        }
      } catch (error) {
        globalThis.postMessage({
          id: request.id,
          type: 'error',
          code: error.code ?? 'PX9199',
          message: error.message ?? 'runtime fault',
          sourceSpan: error.sourceSpan,
        });
      }
    };
  }

  const worker = new Worker(
    URL.createObjectURL(new Blob([`(${workerMain.toString()})();`], { type: 'text/javascript' })),
  );
  let requestId = 1;
  const pending = new Map();
  worker.onmessage = (event) => {
    const callback = pending.get(event.data.id);
    if (!callback) return;
    pending.delete(event.data.id);
    event.data.type === 'error'
      ? callback.reject(new Error(`${event.data.code}: ${event.data.message}`))
      : callback.resolve(event.data);
  };
  const request = (message) =>
    new Promise((resolve, reject) => {
      const id = requestId++;
      pending.set(id, { resolve, reject });
      worker.postMessage({ id, ...message });
    });

  const mapQueries = {};
  for (const [name, asset] of assets)
    if (asset.declaredKind === 'map') {
      mapQueries[name] = {
        layers: asset.layers.map((layer) => ({
          ...layer,
          flags: assets.get(layer.tileSet)?.flags ?? [],
        })),
      };
    }
  let save = {};
  try {
    save = JSON.parse(localStorage.getItem(`px240c/${payload.manifest.id}`) ?? '{}');
  } catch {
    save = {};
  }
  const moduleUrl = URL.createObjectURL(
    new Blob([text('build/cartridge.js')], { type: 'text/javascript' }),
  );

  const graphics = createGraphics(assets, display);
  const audio = createAudio(assets);
  soundButton.addEventListener(
    'click',
    async () => {
      await audio.enable();
      soundButton.textContent = 'SOUND ON';
      soundButton.disabled = true;
    },
    { once: true },
  );

  request({
    type: 'load',
    moduleUrl,
    updateRate: payload.manifest.updateRate,
    maps: mapQueries,
    save,
  })
    .then(() => {
      URL.revokeObjectURL(moduleUrl);
      const tick = async () => {
        try {
          const result = await request({ type: 'frame', input: input() });
          graphics.execute(result.draw);
          graphics.render(context);
          audio.execute(result.audio, result.frame);
          if (result.saveWrites.length) {
            for (const write of result.saveWrites) save[write.key] = write.value;
            localStorage.setItem(`px240c/${payload.manifest.id}`, JSON.stringify(save));
          }
          status.textContent = `F${String(result.frame).padStart(5, '0')} W${String(result.work).padStart(5, '0')}`;
          requestAnimationFrame(tick);
        } catch (error) {
          status.textContent = error.message;
          status.classList.add('error');
        }
      };
      requestAnimationFrame(tick);
    })
    .catch((error) => {
      status.textContent = error.message;
      status.classList.add('error');
    });

  function createGraphics(assetStore, displayConfig) {
    let front = new Uint8Array(240 * 144),
      back = new Uint8Array(240 * 144),
      resolved = new Uint8Array(240 * 144);
    const identity = () => Uint8Array.from({ length: 32 }, (_, index) => index);
    const wrap = (value, size) => ((value % size) + size) % size;
    let raster = [];
    const state = () => ({
      cameraX: 0,
      cameraY: 0,
      clipX: 0,
      clipY: 0,
      clipW: 240,
      clipH: 144,
      remap: displayConfig ? Uint8Array.from(displayConfig.remap) : identity(),
    });
    const plot = (x, y, color, s) => {
      x = Math.trunc(x - s.cameraX);
      y = Math.trunc(y - s.cameraY);
      if (
        x >= s.clipX &&
        y >= s.clipY &&
        x < s.clipX + s.clipW &&
        y < s.clipY + s.clipH &&
        x >= 0 &&
        y >= 0 &&
        x < 240 &&
        y < 144
      )
        back[y * 240 + x] = s.remap[color] ?? 0;
    };
    const line = (x0, y0, x1, y1, color, s) => {
      let dx = Math.abs(x1 - x0),
        sx = x0 < x1 ? 1 : -1,
        dy = -Math.abs(y1 - y0),
        sy = y0 < y1 ? 1 : -1,
        error = dx + dy;
      for (;;) {
        plot(x0, y0, color, s);
        if (x0 === x1 && y0 === y1) break;
        const twice = 2 * error;
        if (twice >= dy) {
          error += dy;
          x0 += sx;
        }
        if (twice <= dx) {
          error += dx;
          y0 += sy;
        }
      }
    };
    const sprite = (asset, x, y, scale, turn, flipX, flipY, s) => {
      if (!asset) return;
      const width = asset.width,
        height = asset.height;
      for (let py = 0; py < height; py++)
        for (let px = 0; px < width; px++) {
          let sx = flipX ? width - 1 - px : px,
            sy = flipY ? height - 1 - py : py;
          const color = asset.pixels?.[sy * width + sx] ?? 0;
          if (color === 0) continue;
          let tx = px,
            ty = py;
          for (let n = 0; n < wrap(turn, 4); n++) {
            const old = tx;
            tx = height - 1 - ty;
            ty = old;
          }
          for (let yy = 0; yy < scale; yy++)
            for (let xx = 0; xx < scale; xx++)
              plot(x + tx * scale + xx, y + ty * scale + yy, color, s);
        }
    };
    const command = (item, s) => {
      const a = item.arguments,
        n = item.name;
      if (n === 'clear') {
        back.fill(s.remap[a[0]] ?? 0);
        return;
      }
      if (n === 'pixel') {
        plot(a[0], a[1], a[2], s);
        return;
      }
      if (n === 'line') {
        line(a[0], a[1], a[2], a[3], a[4], s);
        return;
      }
      if (n === 'rect' || n === 'rect_fill') {
        const [x, y, w, h, c] = a;
        if (n === 'rect') {
          line(x, y, x + w - 1, y, c, s);
          line(x, y + h - 1, x + w - 1, y + h - 1, c, s);
          line(x, y, x, y + h - 1, c, s);
          line(x + w - 1, y, x + w - 1, y + h - 1, c, s);
        } else for (let yy = 0; yy < h; yy++) line(x, y + yy, x + w - 1, y + yy, c, s);
        return;
      }
      if (n === 'circle' || n === 'circle_fill') {
        const [cx, cy, r, c] = a;
        for (let y = -r; y <= r; y++)
          for (let x = -r; x <= r; x++) {
            const d = x * x + y * y;
            if (
              (n === 'circle' && d <= r * r && d > (r - 1) * (r - 1)) ||
              (n === 'circle_fill' && d <= r * r)
            )
              plot(cx + x, cy + y, c, s);
          }
        return;
      }
      if (n === 'triangle') {
        const [x0, y0, x1, y1, x2, y2, c] = a,
          minX = Math.min(x0, x1, x2),
          maxX = Math.max(x0, x1, x2),
          minY = Math.min(y0, y1, y2),
          maxY = Math.max(y0, y1, y2);
        for (let y = minY; y <= maxY; y++)
          for (let x = minX; x <= maxX; x++) {
            const e0 = (x - x1) * (y0 - y1) - (y - y1) * (x0 - x1),
              e1 = (x - x2) * (y1 - y2) - (y - y2) * (x1 - x2),
              e2 = (x - x0) * (y2 - y0) - (y - y0) * (x2 - x0);
            if ((e0 >= 0 && e1 >= 0 && e2 >= 0) || (e0 <= 0 && e1 <= 0 && e2 <= 0))
              plot(x, y, c, s);
          }
        return;
      }
      if (n === 'camera') {
        s.cameraX = a[0];
        s.cameraY = a[1];
        return;
      }
      if (n === 'clip') {
        s.clipX = Math.max(0, a[0]);
        s.clipY = Math.max(0, a[1]);
        s.clipW = Math.max(0, Math.min(240 - s.clipX, a[2]));
        s.clipH = Math.max(0, Math.min(144 - s.clipY, a[3]));
        return;
      }
      if (n === 'clip_reset') {
        s.clipX = 0;
        s.clipY = 0;
        s.clipW = 240;
        s.clipH = 144;
        return;
      }
      if (n === 'pal') {
        s.remap[a[0]] = a[1];
        return;
      }
      if (n === 'pal_reset') {
        s.remap = identity();
        return;
      }
      if (n === 'sprite' || n === 'sprite_xform' || n === 'animation') {
        const asset = assetStore.get(a[0]?.name);
        let image = asset;
        if (n === 'animation')
          image = {
            kind: 'sprite',
            width: asset?.width ?? asset?.frames?.[0]?.length ?? 1,
            height: asset?.height ?? 1,
            pixels: asset?.frames?.[wrap(a[1], asset?.frames?.length ?? 1)],
          };
        if (asset?.frames && n !== 'animation') image = { ...asset, pixels: asset.frames[0] };
        const offset = n === 'animation' ? 2 : 1;
        sprite(
          image,
          a[offset],
          a[offset + 1],
          n === 'sprite_xform' ? a[3] : 1,
          n === 'sprite_xform' ? a[4] : 0,
          n === 'sprite_xform' ? a[5] : false,
          n === 'sprite_xform' ? a[6] : false,
          s,
        );
        return;
      }
      if (n === 'map') {
        const map = assetStore.get(a[0]?.name);
        for (const layer of map?.layers ?? []) {
          const tiles = assetStore.get(layer.tileSet);
          const right = Math.min(240, s.clipX + s.clipW);
          const bottom = Math.min(144, s.clipY + s.clipH);
          const firstX = Math.max(0, Math.floor((s.clipX + s.cameraX - a[1]) / 8));
          const lastX = Math.min(layer.width, Math.ceil((right + s.cameraX - a[1]) / 8));
          const firstY = Math.max(0, Math.floor((s.clipY + s.cameraY - a[2]) / 8));
          const lastY = Math.min(layer.height, Math.ceil((bottom + s.cameraY - a[2]) / 8));
          for (let my = firstY; my < lastY; my++)
            for (let mx = firstX; mx < lastX; mx++) {
              const pixels = tiles?.tiles?.[layer.cells[my * layer.width + mx]];
              sprite(
                { width: 8, height: 8, pixels },
                a[1] + mx * 8,
                a[2] + my * 8,
                1,
                0,
                false,
                false,
                s,
              );
            }
        }
        return;
      }
      if (n === 'print') {
        drawText(String(a[0]), a[1], a[2], a[3], s, plot);
      }
    };
    return {
      execute(commands) {
        back.set(front);
        const s = state();
        raster = [];
        for (const row of displayConfig?.raster ?? [])
          raster[row.line] = {
            scrollX: row.scrollX,
            scrollY: row.scrollY,
            remap: Uint8Array.from(row.remap),
          };
        let rr = identity(),
          rx = 0,
          ry = 0;
        for (const item of commands) {
          if (item.rasterLine === undefined) command(item, s);
          else {
            const a = item.arguments;
            if (item.name === 'pal') rr[a[0]] = a[1];
            else if (item.name === 'raster_scroll') {
              rx = a[0];
              ry = a[1];
            }
            raster[item.rasterLine] = { scrollX: rx, scrollY: ry, remap: rr.slice() };
          }
        }
        let active = { scrollX: 0, scrollY: 0, remap: identity() };
        for (let y = 0; y < 144; y++) {
          active = raster[y] ?? active;
          for (let x = 0; x < 240; x++) {
            const color = back[wrap(y + active.scrollY, 144) * 240 + wrap(x + active.scrollX, 240)];
            resolved[y * 240 + x] = active.remap[color] ?? 0;
          }
        }
        const swap = front;
        front = back;
        back = swap;
      },
      render(ctx) {
        const pixels = new Uint8ClampedArray(240 * 144 * 4);
        for (let i = 0; i < resolved.length; i++) {
          const color = resolved[i] * 4;
          pixels.set(rgba.slice(color, color + 4), i * 4);
        }
        ctx.putImageData(new ImageData(pixels, 240, 144), 0, 0);
      },
    };
  }

  function drawText(value, x, y, color, state, plot) {
    const glyphs = font();
    let px = x,
      py = y;
    for (const character of value) {
      if (character === '\n') {
        px = x;
        py += 8;
        continue;
      }
      const rows = glyphs[character] ?? glyphs[character.toUpperCase()] ?? glyphs['?'];
      for (let row = 0; row < 7; row++)
        for (let column = 0; column < 5; column++)
          if ((rows[row] & (1 << (4 - column))) !== 0) plot(px + column, py + row, color, state);
      px += 6;
    }
  }
  function font() {
    const rows = ` :0,0,0,0,0,0,0|!:4,4,4,4,4,0,4|-:0,0,0,31,0,0,0|.:0,0,0,0,0,12,12|/:1,2,2,4,8,8,16|0:14,17,19,21,25,17,14|1:4,12,4,4,4,4,14|2:14,17,1,2,4,8,31|3:30,1,1,14,1,1,30|4:2,6,10,18,31,2,2|5:31,16,16,30,1,1,30|6:14,16,16,30,17,17,14|7:31,1,2,4,8,8,8|8:14,17,17,14,17,17,14|9:14,17,17,15,1,1,14|::0,12,12,0,12,12,0|?:14,17,1,2,4,0,4|A:14,17,17,31,17,17,17|B:30,17,17,30,17,17,30|C:14,17,16,16,16,17,14|D:28,18,17,17,17,18,28|E:31,16,16,30,16,16,31|F:31,16,16,30,16,16,16|G:14,17,16,23,17,17,15|H:17,17,17,31,17,17,17|I:14,4,4,4,4,4,14|J:7,2,2,2,2,18,12|K:17,18,20,24,20,18,17|L:16,16,16,16,16,16,31|M:17,27,21,21,17,17,17|N:17,25,25,21,19,19,17|O:14,17,17,17,17,17,14|P:30,17,17,30,16,16,16|Q:14,17,17,17,21,18,13|R:30,17,17,30,20,18,17|S:15,16,16,14,1,1,30|T:31,4,4,4,4,4,4|U:17,17,17,17,17,17,14|V:17,17,17,17,17,10,4|W:17,17,17,21,21,21,10|X:17,17,10,4,10,17,17|Y:17,17,10,4,4,4,4|Z:31,1,2,4,8,16,31`;
    return Object.fromEntries(
      rows.split('|').map((item) => {
        const split = item.indexOf(':');
        return [
          item.slice(0, split),
          item
            .slice(split + 1)
            .split(',')
            .map(Number),
        ];
      }),
    );
  }

  function createAudio(assetStore) {
    let audioContext = null,
      tracker = null,
      voices = [];
    const periodicWave = (samples) => {
      const harmonics = Math.min(32, samples.length - 1),
        real = new Float32Array(harmonics + 1),
        imaginary = new Float32Array(harmonics + 1);
      for (let harmonic = 1; harmonic <= harmonics; harmonic++) {
        for (let index = 0; index < samples.length; index++) {
          const phase = (2 * Math.PI * harmonic * index) / samples.length;
          real[harmonic] += (2 * samples[index] * Math.cos(phase)) / samples.length;
          imaginary[harmonic] -= (2 * samples[index] * Math.sin(phase)) / samples.length;
        }
      }
      return audioContext.createPeriodicWave(real, imaginary, { disableNormalization: false });
    };
    const oscillator = (patch, stopAt) => {
      const frequency = 440 * 2 ** ((patch.note - 69) / 12);
      if (patch.waveform === 'noise') {
        const buffer = audioContext.createBuffer(
            1,
            audioContext.sampleRate,
            audioContext.sampleRate,
          ),
          samples = buffer.getChannelData(0);
        let noise = (0x240c1999 ^ patch.note) >>> 0;
        for (let index = 0; index < samples.length; index++) {
          noise ^= noise << 13;
          noise ^= noise >>> 17;
          noise ^= noise << 5;
          samples[index] = (noise >>> 0) / 2147483648 - 1;
        }
        const source = audioContext.createBufferSource();
        source.buffer = buffer;
        source.loop = true;
        source.playbackRate.value = Math.max(0.2, frequency / 440);
        source.start();
        source.stop(stopAt);
        return { source, auxiliaries: [] };
      }
      const source = audioContext.createOscillator();
      if (patch.waveform === 'pulse') {
        const duty = patch.duty ?? 0.5;
        source.setPeriodicWave(
          periodicWave(Array.from({ length: 32 }, (_, index) => (index / 32 < duty ? 1 : -1))),
        );
      } else if (patch.waveform === 'wavetable') {
        source.setPeriodicWave(periodicWave(patch.wavetable));
      } else {
        source.type = patch.waveform === 'saw' ? 'sawtooth' : patch.waveform;
      }
      source.frequency.setValueAtTime(frequency, audioContext.currentTime);
      const pitchEnd = audioContext.currentTime + patch.durationFrames / 60;
      if (patch.pitch.slideSemitonesPerFrame !== 0)
        source.frequency.exponentialRampToValueAtTime(
          Math.max(
            1,
            frequency * 2 ** ((patch.pitch.slideSemitonesPerFrame * patch.durationFrames) / 12),
          ),
          pitchEnd,
        );
      const auxiliaries = [];
      if (patch.pitch.vibratoDepthSemitones > 0 && patch.pitch.vibratoPeriodFrames > 0) {
        const vibrato = audioContext.createOscillator(),
          depth = audioContext.createGain();
        vibrato.frequency.value = 60 / patch.pitch.vibratoPeriodFrames;
        depth.gain.value = frequency * (2 ** (patch.pitch.vibratoDepthSemitones / 12) - 1);
        vibrato.connect(depth).connect(source.frequency);
        vibrato.start();
        vibrato.stop(stopAt);
        auxiliaries.push(vibrato);
      }
      source.start();
      source.stop(stopAt);
      return { source, auxiliaries };
    };
    const play = (patch) => {
      if (!audioContext || !patch) return;
      const now = audioContext.currentTime,
        gain = audioContext.createGain(),
        pan = audioContext.createStereoPanner(),
        attackEnd = now + patch.envelope.attackFrames / 60,
        decayEnd = attackEnd + patch.envelope.decayFrames / 60,
        sustainEnd = Math.max(decayEnd, now + patch.durationFrames / 60),
        releaseEnd = sustainEnd + patch.envelope.releaseFrames / 60,
        voice = oscillator(patch, releaseEnd + 0.02);
      gain.gain.setValueAtTime(patch.envelope.attackFrames === 0 ? patch.volume : 0, now);
      gain.gain.linearRampToValueAtTime(patch.volume, attackEnd);
      gain.gain.linearRampToValueAtTime(patch.volume * patch.envelope.sustainLevel, decayEnd);
      gain.gain.setValueAtTime(patch.volume * patch.envelope.sustainLevel, sustainEnd);
      gain.gain.linearRampToValueAtTime(0, releaseEnd);
      pan.pan.value = patch.pan;
      voice.source.connect(gain).connect(pan).connect(audioContext.destination);
      const active = {
        ...voice,
        stop() {
          try {
            voice.source.stop();
            for (const auxiliary of voice.auxiliaries) auxiliary.stop();
          } catch {
            /* an ended voice is already silent */
          }
        },
      };
      voices.push(active);
      voice.source.addEventListener('ended', () => {
        voices = voices.filter((candidate) => candidate !== active);
      });
      if (voices.length > 8) voices.shift().stop();
    };
    return {
      async enable() {
        audioContext ??= new AudioContext();
        await audioContext.resume();
      },
      execute(commands, frame) {
        for (const command of commands) {
          if (command.name === 'sfx') play(assetStore.get(command.arguments[0]?.name));
          else if (command.name === 'music')
            tracker = {
              asset: assetStore.get(command.arguments[0]?.name),
              order: 0,
              row: 0,
              frame: 0,
            };
          else if (command.name === 'music_stop') tracker = null;
        }
        if (tracker && tracker.asset && tracker.frame++ % tracker.asset.framesPerRow === 0) {
          const name = tracker.asset.order[tracker.order],
            pattern = tracker.asset.patterns[name],
            row = pattern?.rows?.[tracker.row] ?? [];
          for (const cell of row)
            if (cell)
              play({
                ...assetStore.get(cell.sound),
                note: cell.note,
                volume: (assetStore.get(cell.sound)?.volume ?? 1) * (cell.volume ?? 1),
              });
          tracker.row++;
          if (tracker.row >= (pattern?.rows?.length ?? 0)) {
            tracker.row = 0;
            tracker.order++;
            if (tracker.order >= tracker.asset.order.length)
              tracker = tracker.asset.loop ? { ...tracker, order: 0 } : null;
          }
        }
        void frame;
      },
    };
  }
})();
