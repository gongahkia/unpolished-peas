import {
  AudioAssetStore,
  HARDWARE,
  MASTER_PALETTE_RGBA,
  Synthesizer,
  WebAudioSink,
  encodeAssetFile,
  encodeMusicAssetFile,
  encodeSoundAssetFile,
  type MusicAsset,
  type SoundAsset,
  type TrackerCell,
} from '@px240c/runtime';

import type { ProjectManifest } from './compiler';

export type CreationTool = 'sprite' | 'map' | 'palette' | 'sfx' | 'music' | 'project';

export interface ToolProject {
  readonly id: string;
  title: string;
  manifest: string;
  readonly files: Record<string, Uint8Array>;
}

export interface ToolCallbacks {
  readonly back: () => void;
  readonly save: () => Promise<void>;
  readonly parseManifest: () => Promise<ProjectManifest>;
}

const textDecoder = new TextDecoder();

export async function openCreationTool(
  root: HTMLElement,
  tool: CreationTool,
  project: ToolProject,
  callbacks: ToolCallbacks,
): Promise<void> {
  switch (tool) {
    case 'sprite':
      openSpriteEditor(root, project, callbacks);
      break;
    case 'map':
      openMapEditor(root, project, callbacks);
      break;
    case 'palette':
      openPaletteEditor(root, project, callbacks);
      break;
    case 'sfx':
      openSoundEditor(root, project, callbacks);
      break;
    case 'music':
      openMusicEditor(root, project, callbacks);
      break;
    case 'project':
      await openProjectSettings(root, project, callbacks);
      break;
  }
}

interface SpriteDocument {
  revision: 1;
  kind: 'sprite';
  width: number;
  height: number;
  frames: number[][];
}

function openSpriteEditor(root: HTMLElement, project: ToolProject, callbacks: ToolCallbacks): void {
  const path = 'assets/hero.pxg';
  const document = readJson<SpriteDocument>(project.files[path], {
    revision: 1,
    kind: 'sprite',
    width: 16,
    height: 16,
    frames: [Array.from({ length: 256 }, () => 0)],
  });
  root.innerHTML = toolFrame(
    'SPRITE / ANIMATION',
    `<div class="sprite-layout">
      <canvas class="pixel-canvas" width="64" height="64" aria-label="Indexed sprite pixels"></canvas>
      <div class="tool-controls">
        <p>HERO <span class="frame-readout"></span></p>
        <div><button data-act="prev">&lt;F</button><button data-act="next">F&gt;</button><button data-act="add">+F</button></div>
        <div><button data-act="undo">UNDO</button><button data-act="redo">REDO</button></div>
        <div><button data-act="flip-h">FLIP H</button><button data-act="flip-v">FLIP V</button></div>
        <div><button data-act="rotate">ROTATE</button><button data-act="select">SELECT</button></div>
        <label>W <input data-size="width" type="number" min="1" max="64" value="${String(document.width)}"></label>
        <label>H <input data-size="height" type="number" min="1" max="64" value="${String(document.height)}"></label>
        <p class="capacity"></p>
      </div>
      <div class="palette-grid" aria-label="Fixed master palette"></div>
    </div>`,
  );
  bindCommon(root, callbacks);
  const canvas = requireElement(root, '.pixel-canvas') as HTMLCanvasElement;
  const context = requireContext(canvas);
  let frameIndex = 0;
  let color = 23;
  let painting = false;
  let selecting = false;
  let anchor: [number, number] | undefined;
  let selection: [number, number, number, number] | undefined;
  const undo: string[] = [];
  const redo: string[] = [];

  const snapshot = (): string => JSON.stringify(document);
  const remember = (): void => {
    undo.push(snapshot());
    if (undo.length > 32) {
      undo.shift();
    }
    redo.length = 0;
  };
  const restore = (encoded: string): void => {
    Object.assign(document, JSON.parse(encoded) as SpriteDocument);
    frameIndex = Math.min(frameIndex, document.frames.length - 1);
    draw();
  };
  const draw = (): void => {
    context.clearRect(0, 0, 64, 64);
    context.imageSmoothingEnabled = false;
    const scale = Math.max(1, Math.floor(Math.min(64 / document.width, 64 / document.height)));
    const offsetX = Math.floor((64 - document.width * scale) / 2);
    const offsetY = Math.floor((64 - document.height * scale) / 2);
    const previous =
      document.frames[(frameIndex + document.frames.length - 1) % document.frames.length];
    if (document.frames.length > 1 && previous !== undefined) {
      context.globalAlpha = 0.2;
      drawPixels(context, previous, document.width, document.height, scale, offsetX, offsetY);
      context.globalAlpha = 1;
    }
    drawPixels(
      context,
      document.frames[frameIndex] ?? [],
      document.width,
      document.height,
      scale,
      offsetX,
      offsetY,
    );
    context.strokeStyle = paletteCss(24);
    context.lineWidth = 1;
    if (selection !== undefined) {
      const [left, top, right, bottom] = selection;
      context.strokeRect(
        offsetX + left * scale + 0.5,
        offsetY + top * scale + 0.5,
        (right - left + 1) * scale - 1,
        (bottom - top + 1) * scale - 1,
      );
    }
    setText(root, '.frame-readout', `${String(frameIndex + 1)}/${String(document.frames.length)}`);
    setText(
      root,
      '.capacity',
      `${String(document.width * document.height * document.frames.length)} / ${String(HARDWARE.visualCapacityBytes)}B`,
    );
  };
  const point = (event: PointerEvent): [number, number] | undefined => {
    const bounds = canvas.getBoundingClientRect();
    const scale = Math.max(1, Math.floor(Math.min(64 / document.width, 64 / document.height)));
    const offsetX = Math.floor((64 - document.width * scale) / 2);
    const offsetY = Math.floor((64 - document.height * scale) / 2);
    const x = Math.floor(((event.clientX - bounds.left) * 64) / bounds.width - offsetX) / scale;
    const y = Math.floor(((event.clientY - bounds.top) * 64) / bounds.height - offsetY) / scale;
    const pixelX = Math.floor(x);
    const pixelY = Math.floor(y);
    return pixelX >= 0 && pixelY >= 0 && pixelX < document.width && pixelY < document.height
      ? [pixelX, pixelY]
      : undefined;
  };
  const paint = (event: PointerEvent): void => {
    const selected = point(event);
    const frame = document.frames[frameIndex];
    if (selected === undefined || frame === undefined) {
      return;
    }
    const [x, y] = selected;
    frame[y * document.width + x] = event.buttons === 2 ? 0 : color;
    draw();
  };
  canvas.addEventListener('contextmenu', (event) => {
    event.preventDefault();
  });
  canvas.addEventListener('pointerdown', (event) => {
    const selected = point(event);
    if (selected === undefined) {
      return;
    }
    if (selecting) {
      if (anchor === undefined) {
        anchor = selected;
      } else {
        selection = [
          Math.min(anchor[0], selected[0]),
          Math.min(anchor[1], selected[1]),
          Math.max(anchor[0], selected[0]),
          Math.max(anchor[1], selected[1]),
        ];
        anchor = undefined;
        selecting = false;
      }
      draw();
      return;
    }
    remember();
    painting = true;
    canvas.setPointerCapture(event.pointerId);
    paint(event);
  });
  canvas.addEventListener('pointermove', (event) => {
    if (painting) {
      paint(event);
    }
  });
  canvas.addEventListener('pointerup', () => {
    painting = false;
  });
  createPalette(root, (index) => {
    color = index;
  });
  root.querySelectorAll<HTMLElement>('[data-act]').forEach((button) => {
    button.addEventListener('click', () => {
      const action = button.dataset.act;
      if (action === 'undo') {
        const state = undo.pop();
        if (state !== undefined) {
          redo.push(snapshot());
          restore(state);
        }
        return;
      }
      if (action === 'redo') {
        const state = redo.pop();
        if (state !== undefined) {
          undo.push(snapshot());
          restore(state);
        }
        return;
      }
      if (action === 'prev' || action === 'next') {
        const direction = action === 'prev' ? -1 : 1;
        frameIndex = (frameIndex + document.frames.length + direction) % document.frames.length;
      } else if (action === 'add') {
        remember();
        document.frames.splice(frameIndex + 1, 0, [
          ...(document.frames[frameIndex] ??
            Array.from({ length: document.width * document.height }, () => 0)),
        ]);
        frameIndex += 1;
      } else if (action === 'select') {
        selecting = true;
        anchor = undefined;
      } else if (action === 'flip-h' || action === 'flip-v' || action === 'rotate') {
        remember();
        transformSprite(document, frameIndex, action, selection);
      }
      draw();
    });
  });
  root.querySelectorAll<HTMLInputElement>('[data-size]').forEach((input) => {
    input.addEventListener('change', () => {
      remember();
      resizeSprite(
        document,
        clamp(
          Number((requireElement(root, '[data-size="width"]') as HTMLInputElement).value),
          1,
          64,
        ),
        clamp(
          Number((requireElement(root, '[data-size="height"]') as HTMLInputElement).value),
          1,
          64,
        ),
      );
      selection = undefined;
      draw();
    });
  });
  bindSave(root, async () => {
    project.files[path] = encodeAssetFile(document);
    project.manifest = upsertAsset(
      project.manifest,
      'hero',
      document.frames.length > 1 ? 'animation' : 'sprite',
      path,
    );
    await callbacks.save();
  });
  draw();
}

interface MapDocument {
  revision: 1;
  kind: 'map';
  layers: { width: number; height: number; cells: number[]; tileSet: string }[];
}

function openMapEditor(root: HTMLElement, project: ToolProject, callbacks: ToolCallbacks): void {
  const path = 'assets/room.pxm';
  const tilesPath = 'assets/tiles.pxg';
  const document = readJson<MapDocument>(project.files[path], {
    revision: 1,
    kind: 'map',
    layers: [
      { width: 30, height: 18, cells: Array.from({ length: 540 }, () => 0), tileSet: 'tiles' },
    ],
  });
  const tiles = readJson<{ revision: 1; kind: 'tile_set'; tiles: number[][]; flags: number[] }>(
    project.files[tilesPath],
    {
      revision: 1,
      kind: 'tile_set',
      tiles: defaultTiles(),
      flags: [0, 1, 2, 3],
    },
  );
  root.innerHTML = toolFrame(
    'LAYERED TILE MAP',
    `<div class="map-layout">
      <canvas class="map-canvas" width="180" height="108" aria-label="Tile map"></canvas>
      <aside class="map-controls">
        <p>ROOM <span class="layer-readout"></span></p>
        <div class="tile-picks"></div>
        <div><button data-map="prev">&lt;L</button><button data-map="next">L&gt;</button><button data-map="add">+L</button></div>
        <div><button data-map="undo">UNDO</button><button data-map="redo">REDO</button></div>
        <label>FLAG <select class="flag-select"><option value="0">0</option><option value="1">1</option><option value="2">2</option><option value="3">3</option></select></label>
        <button data-map="toggle-flag">TOGGLE</button>
        <p class="capacity"></p>
      </aside>
    </div>`,
  );
  bindCommon(root, callbacks);
  const canvas = requireElement(root, '.map-canvas') as HTMLCanvasElement;
  const context = requireContext(canvas);
  let layer = 0;
  let selectedTile = 1;
  let painting = false;
  const undo: string[] = [];
  const redo: string[] = [];
  const snapshot = (): string => JSON.stringify({ document, tiles });
  const restore = (value: string): void => {
    const state = JSON.parse(value) as { document: MapDocument; tiles: typeof tiles };
    Object.assign(document, state.document);
    Object.assign(tiles, state.tiles);
    layer = Math.min(layer, document.layers.length - 1);
    draw();
  };
  const remember = (): void => {
    undo.push(snapshot());
    if (undo.length > 32) undo.shift();
    redo.length = 0;
  };
  const draw = (): void => {
    const current = document.layers[layer];
    if (current === undefined) return;
    context.fillStyle = paletteCss(1);
    context.fillRect(0, 0, canvas.width, canvas.height);
    const scale = 6;
    for (let y = 0; y < current.height; y += 1) {
      for (let x = 0; x < current.width; x += 1) {
        const tile = current.cells[y * current.width + x] ?? 0;
        context.fillStyle = paletteCss([1, 23, 10, 15][tile] ?? 7);
        context.fillRect(x * scale, y * scale, scale, scale);
      }
    }
    setText(root, '.layer-readout', `${String(layer + 1)}/${String(document.layers.length)}`);
    setText(
      root,
      '.capacity',
      `${String(current.cells.length * 2 + tiles.tiles.length * 64)}B USED`,
    );
  };
  const paint = (event: PointerEvent): void => {
    const current = document.layers[layer];
    if (current === undefined) return;
    const bounds = canvas.getBoundingClientRect();
    const x = Math.floor(((event.clientX - bounds.left) * canvas.width) / bounds.width / 6);
    const y = Math.floor(((event.clientY - bounds.top) * canvas.height) / bounds.height / 6);
    if (x >= 0 && y >= 0 && x < current.width && y < current.height) {
      current.cells[y * current.width + x] = selectedTile;
      draw();
    }
  };
  canvas.addEventListener('pointerdown', (event) => {
    remember();
    painting = true;
    paint(event);
  });
  canvas.addEventListener('pointermove', (event) => {
    if (painting) paint(event);
  });
  canvas.addEventListener('pointerup', () => {
    painting = false;
  });
  const picks = requireElement(root, '.tile-picks');
  for (let index = 0; index < tiles.tiles.length; index += 1) {
    const button = documentElement('button', String(index));
    button.style.background = paletteCss([1, 23, 10, 15][index] ?? 7);
    button.addEventListener('click', () => {
      selectedTile = index;
    });
    picks.append(button);
  }
  root.querySelectorAll<HTMLElement>('[data-map]').forEach((button) => {
    button.addEventListener('click', () => {
      const action = button.dataset.map;
      if (action === 'undo' || action === 'redo') {
        const from = action === 'undo' ? undo : redo;
        const to = action === 'undo' ? redo : undo;
        const state = from.pop();
        if (state !== undefined) {
          to.push(snapshot());
          restore(state);
        }
        return;
      }
      if (action === 'prev' || action === 'next') {
        layer =
          (layer + document.layers.length + (action === 'prev' ? -1 : 1)) % document.layers.length;
      } else if (action === 'add' && document.layers.length < 8) {
        remember();
        const base = document.layers[0];
        if (base !== undefined) {
          document.layers.push({
            width: base.width,
            height: base.height,
            cells: Array.from({ length: base.cells.length }, () => 0),
            tileSet: 'tiles',
          });
          layer = document.layers.length - 1;
        }
      } else if (action === 'toggle-flag') {
        remember();
        const flag = Number((requireElement(root, '.flag-select') as HTMLSelectElement).value);
        tiles.flags[selectedTile] = (tiles.flags[selectedTile] ?? 0) ^ (1 << flag);
      }
      draw();
    });
  });
  bindSave(root, async () => {
    project.files[path] = encodeAssetFile(document);
    project.files[tilesPath] = encodeAssetFile(tiles);
    project.manifest = upsertAsset(project.manifest, 'tiles', 'tile_set', tilesPath);
    project.manifest = upsertAsset(project.manifest, 'room', 'map', path);
    await callbacks.save();
  });
  draw();
}

interface PaletteDocument {
  revision: 1;
  kind: 'display';
  remap: number[];
  raster: { line: number; scrollX: number; scrollY: number; remap: number[] }[];
}

function openPaletteEditor(
  root: HTMLElement,
  project: ToolProject,
  callbacks: ToolCallbacks,
): void {
  const path = 'assets/display.pxp';
  const document = readJson<PaletteDocument>(project.files[path], {
    revision: 1,
    kind: 'display',
    remap: Array.from({ length: 32 }, (_, index) => index),
    raster: [
      { line: 96, scrollX: 0, scrollY: 0, remap: Array.from({ length: 32 }, (_, index) => index) },
    ],
  });
  root.innerHTML = toolFrame(
    'PALETTE / RASTER',
    `<div class="palette-tool">
      <p>MASTER PALETTE IS FIXED / SELECT LOGICAL THEN PHYSICAL</p>
      <div class="master-palette"></div>
      <p>LOGICAL <span class="logical-index">0</span> -&gt; <span class="physical-index">0</span></p>
      <label>RASTER LINE <input class="raster-line" type="range" min="0" max="143" value="${String(document.raster[0]?.line ?? 96)}"></label>
      <label>SCROLL X <input class="scroll-x" type="range" min="-32" max="32" value="${String(document.raster[0]?.scrollX ?? 0)}"></label>
      <label>SCROLL Y <input class="scroll-y" type="range" min="-32" max="32" value="${String(document.raster[0]?.scrollY ?? 0)}"></label>
      <p class="raster-readout"></p>
    </div>`,
  );
  bindCommon(root, callbacks);
  let logical = 0;
  const palette = requireElement(root, '.master-palette');
  for (let index = 0; index < 32; index += 1) {
    const button = documentElement('button', String(index));
    button.style.background = paletteCss(index);
    button.title = `master color ${String(index)}`;
    button.addEventListener('click', () => {
      if (logical === index) {
        logical = (logical + 1) % 32;
      } else {
        document.remap[logical] = index;
      }
      refresh();
    });
    palette.append(button);
  }
  const refresh = (): void => {
    const raster = document.raster[0];
    if (raster === undefined) return;
    raster.line = Number((requireElement(root, '.raster-line') as HTMLInputElement).value);
    raster.scrollX = Number((requireElement(root, '.scroll-x') as HTMLInputElement).value);
    raster.scrollY = Number((requireElement(root, '.scroll-y') as HTMLInputElement).value);
    setText(root, '.logical-index', String(logical));
    setText(root, '.physical-index', String(document.remap[logical] ?? logical));
    setText(
      root,
      '.raster-readout',
      `LINE ${String(raster.line)} SCROLL ${String(raster.scrollX)},${String(raster.scrollY)}`,
    );
  };
  root.querySelectorAll<HTMLInputElement>('input[type="range"]').forEach((input) => {
    input.addEventListener('input', refresh);
  });
  bindSave(root, async () => {
    refresh();
    project.files[path] = encodeAssetFile(document);
    project.manifest = upsertTopLevel(project.manifest, 'display', path);
    await callbacks.save();
  });
  refresh();
}

function openSoundEditor(root: HTMLElement, project: ToolProject, callbacks: ToolCallbacks): void {
  const path = 'assets/blip.pxs';
  const document = readJson<Record<string, unknown>>(project.files[path], defaultSound());
  root.innerHTML = toolFrame('SOUND EFFECT / 8V SYNTH', soundControls(document));
  bindCommon(root, callbacks);
  (requireElement(root, '[name="wave"]') as HTMLSelectElement).value =
    typeof document.waveform === 'string' ? document.waveform : 'pulse';
  const read = (): SoundAsset => soundFromControls(root);
  root.querySelector('[data-preview]')?.addEventListener('click', () => {
    void previewSound(read()).catch((error: unknown) => {
      setToolStatus(root, errorMessage(error), true);
    });
  });
  bindSave(root, async () => {
    project.files[path] = encodeSoundAssetFile(read());
    project.manifest = upsertAsset(project.manifest, 'blip', 'sound', path);
    await callbacks.save();
  });
}

function openMusicEditor(root: HTMLElement, project: ToolProject, callbacks: ToolCallbacks): void {
  const path = 'assets/theme.pxt';
  const existing = readJson<Record<string, unknown> | undefined>(project.files[path], undefined);
  let song = musicDocument(existing);
  root.innerHTML = toolFrame(
    '8-CHANNEL TRACKER',
    `<div class="tracker">
      <div class="tracker-head"><label>F/ROW <input class="tempo" type="number" min="1" max="60" value="${String(numberValue(existing?.framesPerRow, 6))}"></label><label><input class="loop" type="checkbox"${existing?.loop === false ? '' : ' checked'}> LOOP</label><button data-preview>PLAY</button><label>PAT <select class="pattern-select"></select></label><button data-add-pattern title="Add pattern">+PAT</button></div>
      <div class="tracker-order"><label>ORDER <input value=""></label><button data-track-undo>UNDO</button><button data-track-redo>REDO</button></div>
      <div class="tracker-grid" role="grid"></div>
    </div>`,
  );
  bindCommon(root, callbacks);
  const grid = requireElement(root, '.tracker-grid');
  const patternSelect = requireElement(root, '.pattern-select') as HTMLSelectElement;
  const orderInput = requireElement(root, '.tracker-order input') as HTMLInputElement;
  orderInput.value = song.order.join(' ');
  interface HistoryEntry {
    readonly song: EditableMusicDocument;
    readonly order: string;
    readonly selected: string;
  }
  const undo: HistoryEntry[] = [];
  const redo: HistoryEntry[] = [];
  const capture = (order = orderInput.value): HistoryEntry => ({
    song: structuredClone(song),
    order,
    selected: patternSelect.value,
  });
  const remember = (entry = capture()): void => {
    undo.push(entry);
    if (undo.length > 32) undo.shift();
    redo.length = 0;
  };
  const refreshPatternSelect = (selected: string): void => {
    patternSelect.replaceChildren();
    for (const name of Object.keys(song.patterns)) {
      const option = document.createElement('option');
      option.textContent = name;
      option.value = name;
      patternSelect.append(option);
    }
    patternSelect.value = selected;
  };
  const renderPattern = (): void => {
    const name = patternSelect.value;
    const rows = song.patterns[name];
    if (rows === undefined) throw new Error(`pattern '${name}' is missing`);
    grid.replaceChildren();
    grid.setAttribute('aria-label', `Pattern ${name}`);
    for (let row = 0; row < 16; row += 1) {
      const label = documentElement('span', row.toString(16).toUpperCase().padStart(2, '0'));
      grid.append(label);
      for (let channel = 0; channel < 8; channel += 1) {
        const button = documentElement('button', noteLabel(rows[row]?.[channel]?.note ?? null));
        button.setAttribute('role', 'gridcell');
        button.addEventListener('click', () => {
          remember();
          const current = rows[row]?.[channel] ?? null;
          const notes = [null, 48, 55, 60, 64, 67, 72] as const;
          const note = current?.note ?? null;
          const next = notes[(notes.indexOf(note as (typeof notes)[number]) + 1) % notes.length];
          const target = rows[row];
          if (target !== undefined) {
            target[channel] =
              next === null || next === undefined
                ? null
                : { ...current, note: next, sound: current?.sound ?? 'blip' };
          }
          button.textContent = noteLabel(next ?? null);
        });
        grid.append(button);
      }
    }
  };
  refreshPatternSelect(Object.keys(song.patterns)[0] ?? '00');
  renderPattern();
  const restore = (entry: HistoryEntry): void => {
    song = structuredClone(entry.song);
    orderInput.value = entry.order;
    const selected =
      song.patterns[entry.selected] === undefined
        ? (Object.keys(song.patterns)[0] ?? '00')
        : entry.selected;
    refreshPatternSelect(selected);
    renderPattern();
  };
  const stepHistory = (from: HistoryEntry[], to: HistoryEntry[]): void => {
    const entry = from.pop();
    if (entry === undefined) return;
    to.push(capture());
    restore(entry);
  };
  patternSelect.addEventListener('change', renderPattern);
  let orderBefore = orderInput.value;
  orderInput.addEventListener('focus', () => {
    orderBefore = orderInput.value;
  });
  orderInput.addEventListener('change', () => {
    if (orderInput.value !== orderBefore) remember(capture(orderBefore));
  });
  root.querySelector('[data-track-undo]')?.addEventListener('click', () => {
    stepHistory(undo, redo);
  });
  root.querySelector('[data-track-redo]')?.addEventListener('click', () => {
    stepHistory(redo, undo);
  });
  (requireElement(root, '.asset-tool') as HTMLElement).addEventListener('keydown', (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'z') {
      event.preventDefault();
      stepHistory(event.shiftKey ? redo : undo, event.shiftKey ? undo : redo);
    }
  });
  root.querySelector('[data-add-pattern]')?.addEventListener('click', () => {
    const name = nextPatternName(song.patterns);
    if (name === undefined) {
      setToolStatus(root, 'PATTERN LIMIT REACHED', true);
      return;
    }
    remember();
    song.patterns[name] = emptyMusicRows();
    orderInput.value = `${orderInput.value.trim()} ${name}`.trim();
    refreshPatternSelect(name);
    renderPattern();
    setToolStatus(root, `PATTERN ${name} ADDED`, false);
  });
  const read = (): MusicAsset => musicFromDocument(root, song);
  root.querySelector('[data-preview]')?.addEventListener('click', () => {
    void callbacks
      .parseManifest()
      .then((manifest) => previewMusic(read(), musicSounds(project, manifest)))
      .catch((error: unknown) => {
        setToolStatus(root, errorMessage(error), true);
      });
  });
  bindSave(root, async () => {
    const music = read();
    const usesBlip = Object.values(music.patterns).some((pattern) =>
      pattern.rows.some((row) => row.some((cell) => cell?.sound === 'blip')),
    );
    if (usesBlip && project.files['assets/blip.pxs'] === undefined) {
      project.files['assets/blip.pxs'] = encodeAssetFile(defaultSound());
      project.manifest = upsertAsset(project.manifest, 'blip', 'sound', 'assets/blip.pxs');
    }
    project.files[path] = encodeMusicAssetFile(music);
    project.manifest = upsertAsset(project.manifest, 'theme', 'music', path);
    await callbacks.save();
  });
}

async function openProjectSettings(
  root: HTMLElement,
  project: ToolProject,
  callbacks: ToolCallbacks,
): Promise<void> {
  const manifest = await callbacks.parseManifest();
  root.innerHTML = toolFrame(
    'CARTRIDGE SETTINGS',
    `<form class="project-settings">
      <label>ID <input value="" disabled></label>
      <label>TITLE <input name="title" maxlength="64"></label>
      <label>AUTHOR <input name="author" maxlength="64"></label>
      <label>VERSION <input name="version" maxlength="32"></label>
      <label>UPDATE <select name="update"><option value="60">60 HZ</option><option value="30">30 HZ</option></select></label>
      <p>SOURCE AND CARTRIDGE OWNERSHIP REMAIN WITH THE AUTHOR.</p>
    </form>`,
  );
  bindCommon(root, callbacks);
  const form = requireElement(root, '.project-settings') as HTMLFormElement;
  const controls = form.elements as typeof form.elements & {
    title: HTMLInputElement;
    author: HTMLInputElement;
    version: HTMLInputElement;
    update: HTMLSelectElement;
  };
  (form.querySelector('input[disabled]') as HTMLInputElement).value = manifest.id;
  controls.title.value = manifest.title;
  controls.author.value = manifest.author;
  controls.version.value = manifest.version;
  controls.update.value = String(manifest.update_rate);
  bindSave(root, async () => {
    project.title = controls.title.value;
    project.manifest = upsertTopLevel(project.manifest, 'title', controls.title.value);
    project.manifest = upsertTopLevel(project.manifest, 'author', controls.author.value);
    project.manifest = upsertTopLevel(project.manifest, 'version', controls.version.value);
    project.manifest = upsertTopLevel(
      project.manifest,
      'update_rate',
      Number(controls.update.value),
    );
    await callbacks.save();
  });
}

function bindCommon(root: HTMLElement, callbacks: ToolCallbacks): void {
  root.querySelector('[data-common="back"]')?.addEventListener('click', callbacks.back);
  const panel = requireElement(root, '.asset-tool') as HTMLElement;
  panel.tabIndex = -1;
  panel.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      callbacks.back();
    } else if (event.key === 'F3') {
      event.preventDefault();
      root.querySelector<HTMLButtonElement>('[data-common="save"]')?.click();
    }
  });
  panel.focus();
}

function bindSave(root: HTMLElement, save: () => Promise<void>): void {
  root.querySelector('[data-common="save"]')?.addEventListener('click', () => {
    void save()
      .then(() => {
        setToolStatus(root, 'SAVED', false);
      })
      .catch((error: unknown) => {
        setToolStatus(root, errorMessage(error), true);
      });
  });
}

function toolFrame(title: string, body: string): string {
  return `<section class="display asset-tool" data-view="tool" aria-label="${title}">
    <header class="system-bar"><span>${title}</span><span>PXCL/1</span></header>
    <main class="tool-stage">${body}</main>
    <p class="tool-status" role="status" aria-live="polite">READY</p>
    <footer class="tool-bar"><button type="button" data-common="back">ESC BACK</button><button type="button" data-common="save">F3 SAVE</button></footer>
  </section>`;
}

function createPalette(root: ParentNode, select: (index: number) => void): void {
  const palette = requireElement(root, '.palette-grid');
  for (let index = 0; index < 32; index += 1) {
    const button = documentElement('button', String(index));
    button.style.background = paletteCss(index);
    button.title = `color ${String(index)}`;
    button.addEventListener('click', () => {
      select(index);
    });
    palette.append(button);
  }
}

function drawPixels(
  context: CanvasRenderingContext2D,
  pixels: readonly number[],
  width: number,
  height: number,
  scale: number,
  offsetX: number,
  offsetY: number,
): void {
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const color = pixels[y * width + x] ?? 0;
      if (color !== 0) {
        context.fillStyle = paletteCss(color);
        context.fillRect(offsetX + x * scale, offsetY + y * scale, scale, scale);
      }
    }
  }
}

function transformSprite(
  document: SpriteDocument,
  frameIndex: number,
  action: string,
  selection: [number, number, number, number] | undefined,
): void {
  const frame = document.frames[frameIndex];
  if (frame === undefined) return;
  const [left, top, right, bottom] = selection ?? [0, 0, document.width - 1, document.height - 1];
  const source = [...frame];
  const width = right - left + 1;
  const height = bottom - top + 1;
  for (let y = top; y <= bottom; y += 1) {
    for (let x = left; x <= right; x += 1) {
      let sourceX = action === 'flip-h' ? right - (x - left) : x;
      let sourceY = action === 'flip-v' ? bottom - (y - top) : y;
      if (action === 'rotate' && width === height) {
        sourceX = left + (y - top);
        sourceY = bottom - (x - left);
      }
      frame[y * document.width + x] = source[sourceY * document.width + sourceX] ?? 0;
    }
  }
}

function resizeSprite(document: SpriteDocument, width: number, height: number): void {
  document.frames = document.frames.map((frame) => {
    const resized = Array.from({ length: width * height }, () => 0);
    for (let y = 0; y < Math.min(height, document.height); y += 1) {
      for (let x = 0; x < Math.min(width, document.width); x += 1) {
        resized[y * width + x] = frame[y * document.width + x] ?? 0;
      }
    }
    return resized;
  });
  document.width = width;
  document.height = height;
}

function defaultTiles(): number[][] {
  return [1, 23, 10, 15].map((color, tile) =>
    Array.from({ length: 64 }, (_, index) =>
      tile === 0 || (index + Math.floor(index / 8)) % (tile + 2) === 0 ? color : 1,
    ),
  );
}

function defaultSound(): Record<string, unknown> {
  return {
    revision: 1,
    kind: 'sound',
    waveform: 'pulse',
    note: 60,
    durationFrames: 18,
    volume: 0.6,
    pan: 0,
    duty: 0.5,
    envelope: { attackFrames: 1, decayFrames: 3, sustainLevel: 0.65, releaseFrames: 4 },
    pitch: { slideSemitonesPerFrame: 0, vibratoDepthSemitones: 0, vibratoPeriodFrames: 0 },
  };
}

function soundControls(value: Record<string, unknown>): string {
  const envelope = isRecord(value.envelope) ? value.envelope : {};
  const pitch = isRecord(value.pitch) ? value.pitch : {};
  return `<div class="sound-controls">
    <label>WAVE <select name="wave"><option>pulse</option><option>triangle</option><option>saw</option><option>noise</option><option>wavetable</option></select></label>
    ${rangeControl('NOTE', 'note', numberValue(value.note, 60), 24, 96, 1)}
    ${rangeControl('LENGTH', 'duration', numberValue(value.durationFrames, 18), 1, 120, 1)}
    ${rangeControl('VOLUME', 'volume', numberValue(value.volume, 0.6), 0, 1, 0.05)}
    ${rangeControl('PAN', 'pan', numberValue(value.pan, 0), -1, 1, 0.1)}
    ${rangeControl('ATTACK', 'attack', numberValue(envelope.attackFrames, 1), 0, 30, 1)}
    ${rangeControl('DECAY', 'decay', numberValue(envelope.decayFrames, 3), 0, 30, 1)}
    ${rangeControl('SUSTAIN', 'sustain', numberValue(envelope.sustainLevel, 0.65), 0, 1, 0.05)}
    ${rangeControl('RELEASE', 'release', numberValue(envelope.releaseFrames, 4), 0, 30, 1)}
    ${rangeControl('SLIDE', 'slide', numberValue(pitch.slideSemitonesPerFrame, 0), -1, 1, 0.05)}
    ${rangeControl('VIBRATO', 'vibrato', numberValue(pitch.vibratoDepthSemitones, 0), 0, 4, 0.1)}
    <button type="button" data-preview>PREVIEW</button>
  </div>`;
}

function rangeControl(
  label: string,
  name: string,
  value: number,
  minimum: number,
  maximum: number,
  step: number,
): string {
  return `<label>${label} <input name="${name}" type="range" min="${String(minimum)}" max="${String(maximum)}" step="${String(step)}" value="${String(value)}"></label>`;
}

function soundFromControls(root: ParentNode): SoundAsset {
  const value = (name: string): number =>
    Number((requireElement(root, `[name="${name}"]`) as HTMLInputElement).value);
  const wave = (requireElement(root, '[name="wave"]') as HTMLSelectElement)
    .value as SoundAsset['waveform'];
  return {
    kind: 'sound',
    name: 'blip',
    waveform: wave,
    note: value('note'),
    durationFrames: value('duration'),
    volume: value('volume'),
    pan: value('pan'),
    ...(wave === 'pulse' ? { duty: 0.5 } : {}),
    ...(wave === 'wavetable' ? { wavetable: [0, 0.7, 1, 0.7, 0, -0.7, -1, -0.7] } : {}),
    envelope: {
      attackFrames: value('attack'),
      decayFrames: value('decay'),
      sustainLevel: value('sustain'),
      releaseFrames: value('release'),
    },
    pitch: {
      slideSemitonesPerFrame: value('slide'),
      vibratoDepthSemitones: value('vibrato'),
      vibratoPeriodFrames: value('vibrato') === 0 ? 0 : 8,
    },
  };
}

async function previewSound(sound: SoundAsset): Promise<void> {
  const synth = new Synthesizer(new AudioAssetStore([sound]));
  const sink = new WebAudioSink();
  await sink.resume();
  for (let frame = 0; frame < sound.durationFrames + sound.envelope.releaseFrames; frame += 1) {
    sink.enqueue(
      synth.executeFrame(
        frame === 0
          ? [
              {
                name: 'sfx',
                arguments: [{ name: sound.name, kind: 'Sound' }],
                sourceSpan: { start: 0, end: 0 },
              },
            ]
          : [],
      ),
    );
  }
  setTimeout(() => void sink.close(), 2_000);
}

type EditableMusicRows = (TrackerCell | null)[][];

interface EditableMusicDocument {
  readonly order: string[];
  readonly patterns: Record<string, EditableMusicRows>;
}

function emptyMusicRows(): EditableMusicRows {
  return Array.from({ length: 16 }, () => Array.from<TrackerCell | null>({ length: 8 }).fill(null));
}

function musicDocument(value: Record<string, unknown> | undefined): EditableMusicDocument {
  const patterns: Record<string, EditableMusicRows> = {};
  if (value !== undefined && isRecord(value.patterns)) {
    for (const [name, rawPattern] of Object.entries(value.patterns)) {
      if (!isRecord(rawPattern) || !Array.isArray(rawPattern.rows)) continue;
      const rows = emptyMusicRows();
      for (let row = 0; row < rows.length; row += 1) {
        const target = rows[row];
        if (target === undefined) continue;
        for (let channel = 0; channel < 8; channel += 1) {
          const cell: unknown = (rawPattern.rows as unknown[][])[row]?.[channel];
          if (isRecord(cell) && typeof cell.note === 'number' && typeof cell.sound === 'string') {
            target[channel] = {
              note: cell.note,
              sound: cell.sound,
              ...(typeof cell.volume === 'number' ? { volume: cell.volume } : {}),
            };
          }
        }
      }
      patterns[name] = rows;
    }
  }
  if (Object.keys(patterns).length === 0) patterns['00'] = emptyMusicRows();
  const order = Array.isArray(value?.order)
    ? value.order.filter(
        (name): name is string => typeof name === 'string' && patterns[name] !== undefined,
      )
    : [];
  return { order: order.length === 0 ? [Object.keys(patterns)[0] ?? '00'] : order, patterns };
}

function nextPatternName(
  patterns: Readonly<Record<string, EditableMusicRows>>,
): string | undefined {
  for (let index = 0; index <= 0xff; index += 1) {
    const name = index.toString(16).toUpperCase().padStart(2, '0');
    if (patterns[name] === undefined) return name;
  }
  return undefined;
}

function musicFromDocument(root: ParentNode, document: EditableMusicDocument): MusicAsset {
  const order = (requireElement(root, '.tracker-order input') as HTMLInputElement).value
    .split(/[\s,]+/u)
    .filter((name) => name.length > 0);
  if (order.length === 0) throw new Error('order list cannot be empty');
  const missing = order.find((name) => document.patterns[name] === undefined);
  if (missing !== undefined) throw new Error(`order references missing pattern '${missing}'`);
  return {
    kind: 'music',
    name: 'theme',
    framesPerRow: Number((requireElement(root, '.tempo') as HTMLInputElement).value),
    order,
    patterns: Object.fromEntries(
      Object.entries(document.patterns).map(([name, rows]) => [name, { rows }]),
    ),
    loop: (requireElement(root, '.loop') as HTMLInputElement).checked,
  };
}

function musicSounds(project: ToolProject, manifest: ProjectManifest): SoundAsset[] {
  return Object.entries(manifest.assets).flatMap(([name, asset]) => {
    if (asset.kind !== 'sound') return [];
    const value = readJson<Record<string, unknown> | undefined>(
      project.files[asset.path],
      undefined,
    );
    return value === undefined ? [] : [{ ...value, name } as unknown as SoundAsset];
  });
}

async function previewMusic(music: MusicAsset, sounds: readonly SoundAsset[]): Promise<void> {
  const assets = [...sounds];
  if (!assets.some((sound) => sound.name === 'blip')) {
    assets.push({ ...defaultSound(), name: 'blip' } as unknown as SoundAsset);
  }
  const synth = new Synthesizer(new AudioAssetStore([...assets, music]));
  const sink = new WebAudioSink();
  await sink.resume();
  const frames =
    music.framesPerRow *
    music.order.reduce((rows, name) => rows + (music.patterns[name]?.rows.length ?? 0), 0);
  for (let frame = 0; frame < frames; frame += 1) {
    sink.enqueue(
      synth.executeFrame(
        frame === 0
          ? [
              {
                name: 'music',
                arguments: [{ name: music.name, kind: 'Music' }],
                sourceSpan: { start: 0, end: 0 },
              },
            ]
          : [],
      ),
    );
  }
  setTimeout(() => void sink.close(), 4_000);
}

function noteLabel(note: number | null): string {
  return note === null ? '--' : note.toString(16).toUpperCase().padStart(2, '0');
}

function upsertAsset(manifest: string, name: string, kind: string, path: string): string {
  const section = `[assets.${name}]\nkind = "${kind}"\npath = "${path}"\n`;
  const matcher = new RegExp(`\\[assets\\.${name}\\]\\n[\\s\\S]*?(?=\\n\\[|$)`);
  if (matcher.test(manifest)) {
    return manifest.replace(matcher, section.trimEnd());
  }
  return `${manifest.trimEnd()}\n\n${section}`;
}

function upsertTopLevel(manifest: string, key: string, value: string | number): string {
  const encoded = typeof value === 'number' ? String(value) : JSON.stringify(value);
  const line = `${key} = ${encoded}`;
  const matcher = new RegExp(`^${key}\\s*=.*$`, 'm');
  if (matcher.test(manifest)) return manifest.replace(matcher, line);
  const section = manifest.indexOf('\n[');
  return section < 0
    ? `${manifest.trimEnd()}\n${line}\n`
    : `${manifest.slice(0, section)}\n${line}${manifest.slice(section)}`;
}

function paletteCss(index: number): string {
  const offset = clamp(index, 0, 31) * 4;
  const red = MASTER_PALETTE_RGBA[offset] ?? 0;
  const green = MASTER_PALETTE_RGBA[offset + 1] ?? 0;
  const blue = MASTER_PALETTE_RGBA[offset + 2] ?? 0;
  return `rgb(${String(red)} ${String(green)} ${String(blue)})`;
}

function readJson<Value>(bytes: Uint8Array | undefined, fallback: Value): Value {
  if (bytes === undefined) return fallback;
  try {
    return JSON.parse(textDecoder.decode(bytes)) as Value;
  } catch {
    return fallback;
  }
}

function documentElement(tag: 'button' | 'span', text: string): HTMLElement {
  const element = document.createElement(tag);
  if (tag === 'button') element.setAttribute('type', 'button');
  element.textContent = text;
  return element;
}

function requireContext(canvas: HTMLCanvasElement): CanvasRenderingContext2D {
  const context = canvas.getContext('2d');
  if (context === null) throw new Error('2D canvas is unavailable');
  return context;
}

function setText(root: ParentNode, selector: string, value: string): void {
  requireElement(root, selector).textContent = value;
}

function setToolStatus(root: ParentNode, message: string, error: boolean): void {
  const status = requireElement(root, '.tool-status');
  status.textContent = message;
  status.classList.toggle('error', error);
}

function requireElement(root: ParentNode, selector: string): Element {
  const element = root.querySelector(selector);
  if (element === null) throw new Error(`tool element '${selector}' is missing`);
  return element;
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.max(minimum, Math.min(maximum, Math.round(value)));
}

function numberValue(value: unknown, fallback: number): number {
  return typeof value === 'number' ? value : fallback;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message.toUpperCase() : 'TOOL ERROR';
}
