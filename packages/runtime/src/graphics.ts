import { HARDWARE, MASTER_PALETTE_RGBA } from './hardware';
import { BITMAP_FONT, glyphRows } from './font';
import type { ConsoleCommand } from './protocol';

export interface IndexedSprite {
  readonly kind: 'sprite';
  readonly name: string;
  readonly width: number;
  readonly height: number;
  readonly pixels: Uint8Array;
}

export interface IndexedAnimation {
  readonly kind: 'animation';
  readonly name: string;
  readonly frames: readonly IndexedSprite[];
}

export interface IndexedTileSet {
  readonly kind: 'tile_set';
  readonly name: string;
  readonly tiles: readonly IndexedSprite[];
  readonly flags: Uint8Array;
}

export interface IndexedMapLayer {
  readonly width: number;
  readonly height: number;
  readonly cells: Uint16Array;
  readonly tileSet: string;
}

export interface IndexedMap {
  readonly kind: 'map';
  readonly name: string;
  readonly layers: readonly IndexedMapLayer[];
}

export type VisualAsset = IndexedSprite | IndexedAnimation | IndexedTileSet | IndexedMap;

export interface DisplayRasterState {
  readonly line: number;
  readonly scrollX: number;
  readonly scrollY: number;
  readonly remap: Uint8Array;
}

export interface DisplayConfiguration {
  readonly remap: Uint8Array;
  readonly raster: readonly DisplayRasterState[];
}

interface DrawState {
  cameraX: number;
  cameraY: number;
  clipX: number;
  clipY: number;
  clipWidth: number;
  clipHeight: number;
  readonly remap: Uint8Array;
}

export interface GraphicsFrame {
  readonly indexedPixels: Uint8Array;
  readonly commands: number;
}

export interface GraphicsSnapshot {
  readonly revision: 1;
  readonly front: Uint8Array;
  readonly resolved: Uint8Array;
}

/** Validated, capacity-accounted assets shared by sprite and map drawing. */
export class VisualAssetStore {
  private readonly entries = new Map<string, VisualAsset>();
  public readonly usedBytes: number;

  public constructor(assets: readonly VisualAsset[] = []) {
    let usedBytes = 0;
    for (const asset of assets) {
      if (this.entries.has(asset.name)) {
        throw new TypeError(`duplicate visual asset '${asset.name}'`);
      }
      validateAsset(asset);
      usedBytes += visualAssetBytes(asset);
      if (usedBytes > HARDWARE.visualCapacityBytes) {
        throw new RangeError('visual assets exceed the 128 KiB shared capacity');
      }
      this.entries.set(asset.name, asset);
    }
    for (const asset of assets) {
      if (asset.kind !== 'map') {
        continue;
      }
      for (const layer of asset.layers) {
        const tileSet = this.entries.get(layer.tileSet);
        if (
          tileSet?.kind !== 'tile_set' ||
          layer.cells.some((tile) => tile >= tileSet.tiles.length)
        ) {
          throw new TypeError(`map '${asset.name}' references an invalid tile set or tile`);
        }
      }
    }
    this.usedBytes = usedBytes;
  }

  public get(name: string): VisualAsset | undefined {
    return this.entries.get(name);
  }

  public mapCell(name: string, layer: number, x: number, y: number): number | undefined {
    const asset = this.entries.get(name);
    if (asset?.kind !== 'map') {
      return undefined;
    }
    const selected = asset.layers[layer];
    if (selected === undefined || x < 0 || y < 0 || x >= selected.width || y >= selected.height) {
      return undefined;
    }
    return selected.cells[y * selected.width + x];
  }

  public mapFlag(name: string, layer: number, x: number, y: number, flag: number): boolean {
    const asset = this.entries.get(name);
    if (asset?.kind !== 'map' || flag < 0 || flag > 7) {
      return false;
    }
    const selected = asset.layers[layer];
    if (selected === undefined) {
      return false;
    }
    const tile = this.mapCell(name, layer, x, y);
    const tileSet = this.entries.get(selected.tileSet);
    return (
      tile !== undefined &&
      tileSet?.kind === 'tile_set' &&
      ((tileSet.flags[tile] ?? 0) & (1 << flag)) !== 0
    );
  }
}

/** Deterministic indexed immediate-mode rasterizer with double-buffered storage. */
export class IndexedGraphics {
  private front = new Uint8Array(HARDWARE.width * HARDWARE.height);
  private back = new Uint8Array(HARDWARE.width * HARDWARE.height);
  private readonly resolved = new Uint8Array(HARDWARE.width * HARDWARE.height);
  private readonly assets: VisualAssetStore;
  private readonly display: DisplayConfiguration;

  public constructor(assets = new VisualAssetStore(), display?: DisplayConfiguration) {
    this.assets = assets;
    this.display = copyDisplayConfiguration(display);
  }

  public executeFrame(commands: readonly ConsoleCommand[]): GraphicsFrame {
    if (commands.length > HARDWARE.drawCommandsPerFrame) {
      throw new RangeError('draw-command ceiling exceeded');
    }
    this.back.set(this.front);
    const state = initialDrawState(this.display.remap);
    const rasterRemaps = Array.from(
      { length: HARDWARE.height },
      () => new Uint8Array(HARDWARE.paletteSize),
    );
    const rasterScrollX = new Int16Array(HARDWARE.height);
    const rasterScrollY = new Int16Array(HARDWARE.height);
    const rasterStateSet = new Uint8Array(HARDWARE.height);
    const displayRemap = identityRemap();
    let displayScrollX = 0;
    let displayScrollY = 0;

    for (const raster of this.display.raster) {
      rasterRemaps[raster.line]?.set(raster.remap);
      rasterScrollX[raster.line] = raster.scrollX;
      rasterScrollY[raster.line] = raster.scrollY;
      rasterStateSet[raster.line] = 1;
    }

    for (const command of commands) {
      if (command.rasterLine === undefined) {
        this.executeDraw(command, state);
        continue;
      }
      const line = command.rasterLine;
      if (line < 0 || line >= HARDWARE.height) {
        throw new RangeError('raster command has an invalid scanline');
      }
      if (command.name === 'pal') {
        const [from, to] = expectIntegers(command, 2);
        displayRemap[expectColor(from)] = expectColor(to);
      } else if (command.name === 'raster_scroll') {
        [displayScrollX, displayScrollY] = expectIntegers(command, 2);
      } else {
        throw new TypeError(`'${command.name}' is not valid during raster display`);
      }
      rasterScrollX[line] = clampInt16(displayScrollX);
      rasterScrollY[line] = clampInt16(displayScrollY);
      rasterRemaps[line]?.set(displayRemap);
      rasterStateSet[line] = 1;
    }

    let previousRemap = identityRemap();
    let previousScrollX = 0;
    let previousScrollY = 0;
    for (let y = 0; y < HARDWARE.height; y += 1) {
      const lineRemap = rasterRemaps[y];
      if (lineRemap !== undefined && rasterStateSet[y] === 1) {
        previousRemap = lineRemap;
        previousScrollX = rasterScrollX[y] ?? 0;
        previousScrollY = rasterScrollY[y] ?? 0;
      }
      for (let x = 0; x < HARDWARE.width; x += 1) {
        const sourceX = wrap(x + previousScrollX, HARDWARE.width);
        const sourceY = wrap(y + previousScrollY, HARDWARE.height);
        const color = this.back[sourceY * HARDWARE.width + sourceX] ?? 0;
        this.resolved[y * HARDWARE.width + x] = previousRemap[color] ?? 0;
      }
    }

    const previousFront = this.front;
    this.front = this.back;
    this.back = previousFront;
    return { indexedPixels: this.resolved.slice(), commands: commands.length };
  }

  public snapshot(): GraphicsSnapshot {
    return { revision: 1, front: this.front.slice(), resolved: this.resolved.slice() };
  }

  public restore(snapshot: unknown): void {
    const pixelCount = HARDWARE.width * HARDWARE.height;
    if (
      !isRecord(snapshot) ||
      snapshot.revision !== 1 ||
      !(snapshot.front instanceof Uint8Array) ||
      snapshot.front.length !== pixelCount ||
      snapshot.front.some((color) => color >= HARDWARE.paletteSize) ||
      !(snapshot.resolved instanceof Uint8Array) ||
      snapshot.resolved.length !== pixelCount ||
      snapshot.resolved.some((color) => color >= HARDWARE.paletteSize)
    ) {
      throw new TypeError('invalid indexed graphics snapshot');
    }
    this.front.set(snapshot.front);
    this.back.set(snapshot.front);
    this.resolved.set(snapshot.resolved);
  }

  private executeDraw(command: ConsoleCommand, state: DrawState): void {
    switch (command.name) {
      case 'clear': {
        const [color] = expectIntegers(command, 1);
        this.back.fill(state.remap[expectColor(color)] ?? 0);
        return;
      }
      case 'pixel': {
        const [x, y, color] = expectIntegers(command, 3);
        this.plot(x, y, color, state);
        return;
      }
      case 'line': {
        const [x0, y0, x1, y1, color] = expectIntegers(command, 5);
        this.line(x0, y0, x1, y1, color, state);
        return;
      }
      case 'rect':
      case 'rect_fill': {
        const [x, y, width, height, color] = expectIntegers(command, 5);
        this.rectangle(x, y, width, height, color, command.name === 'rect_fill', state);
        return;
      }
      case 'circle':
      case 'circle_fill': {
        const [x, y, radius, color] = expectIntegers(command, 4);
        this.circle(x, y, radius, color, command.name === 'circle_fill', state);
        return;
      }
      case 'triangle': {
        const [x0, y0, x1, y1, x2, y2, color] = expectIntegers(command, 7);
        this.triangle(x0, y0, x1, y1, x2, y2, color, state);
        return;
      }
      case 'camera':
        [state.cameraX, state.cameraY] = expectIntegers(command, 2);
        return;
      case 'clip': {
        const [x, y, width, height] = expectIntegers(command, 4);
        state.clipX = x;
        state.clipY = y;
        state.clipWidth = Math.max(0, width);
        state.clipHeight = Math.max(0, height);
        return;
      }
      case 'clip_reset':
        expectIntegers(command, 0);
        state.clipX = 0;
        state.clipY = 0;
        state.clipWidth = HARDWARE.width;
        state.clipHeight = HARDWARE.height;
        return;
      case 'pal': {
        const [from, to] = expectIntegers(command, 2);
        state.remap[expectColor(from)] = expectColor(to);
        return;
      }
      case 'pal_reset':
        expectIntegers(command, 0);
        state.remap.set(identityRemap());
        return;
      case 'sprite': {
        const [handle, x, y] = command.arguments;
        this.drawSprite(readAssetName(handle, 'Sprite'), expectInteger(x), expectInteger(y), state);
        return;
      }
      case 'animation': {
        const [handle, frame, x, y] = command.arguments;
        this.drawAnimation(
          readAssetName(handle, 'Animation'),
          expectInteger(frame),
          expectInteger(x),
          expectInteger(y),
          state,
        );
        return;
      }
      case 'sprite_xform': {
        const [handle, x, y, scale, quarterTurns, flipX, flipY] = command.arguments;
        this.drawTransformedSprite(
          readAssetName(handle, 'Sprite'),
          expectInteger(x),
          expectInteger(y),
          expectInteger(scale),
          expectInteger(quarterTurns),
          expectBoolean(flipX),
          expectBoolean(flipY),
          state,
        );
        return;
      }
      case 'map': {
        const [handle, x, y] = command.arguments;
        this.drawMap(readAssetName(handle, 'Map'), expectInteger(x), expectInteger(y), state);
        return;
      }
      case 'raster_scroll':
        throw new TypeError('raster_scroll is only valid in the raster callback');
      case 'print': {
        const [text, x, y, color] = command.arguments;
        this.print(
          expectText(text),
          expectInteger(x),
          expectInteger(y),
          expectInteger(color),
          state,
        );
        return;
      }
      default:
        throw new TypeError(`unknown graphics command '${command.name}'`);
    }
  }

  private plot(x: number, y: number, color: number, state: DrawState): void {
    const screenX = x - state.cameraX;
    const screenY = y - state.cameraY;
    if (
      screenX < 0 ||
      screenX >= HARDWARE.width ||
      screenY < 0 ||
      screenY >= HARDWARE.height ||
      screenX < state.clipX ||
      screenX >= state.clipX + state.clipWidth ||
      screenY < state.clipY ||
      screenY >= state.clipY + state.clipHeight
    ) {
      return;
    }
    this.back[screenY * HARDWARE.width + screenX] = state.remap[expectColor(color)] ?? 0;
  }

  private line(
    startX: number,
    startY: number,
    endX: number,
    endY: number,
    color: number,
    state: DrawState,
  ): void {
    let x = startX;
    let y = startY;
    const deltaX = Math.abs(endX - startX);
    const stepX = startX < endX ? 1 : -1;
    const deltaY = -Math.abs(endY - startY);
    const stepY = startY < endY ? 1 : -1;
    let error = deltaX + deltaY;
    for (;;) {
      this.plot(x, y, color, state);
      if (x === endX && y === endY) {
        return;
      }
      const doubled = error * 2;
      if (doubled >= deltaY) {
        error += deltaY;
        x += stepX;
      }
      if (doubled <= deltaX) {
        error += deltaX;
        y += stepY;
      }
    }
  }

  private rectangle(
    x: number,
    y: number,
    width: number,
    height: number,
    color: number,
    filled: boolean,
    state: DrawState,
  ): void {
    if (width <= 0 || height <= 0) {
      return;
    }
    if (!filled) {
      this.line(x, y, x + width - 1, y, color, state);
      this.line(x, y + height - 1, x + width - 1, y + height - 1, color, state);
      this.line(x, y, x, y + height - 1, color, state);
      this.line(x + width - 1, y, x + width - 1, y + height - 1, color, state);
      return;
    }
    for (let row = 0; row < height; row += 1) {
      this.line(x, y + row, x + width - 1, y + row, color, state);
    }
  }

  private circle(
    centerX: number,
    centerY: number,
    radius: number,
    color: number,
    filled: boolean,
    state: DrawState,
  ): void {
    if (radius < 0) {
      return;
    }
    let x = radius;
    let y = 0;
    let error = 1 - radius;
    while (x >= y) {
      if (filled) {
        this.line(centerX - x, centerY + y, centerX + x, centerY + y, color, state);
        this.line(centerX - x, centerY - y, centerX + x, centerY - y, color, state);
        this.line(centerX - y, centerY + x, centerX + y, centerY + x, color, state);
        this.line(centerX - y, centerY - x, centerX + y, centerY - x, color, state);
      } else {
        for (const [plotX, plotY] of [
          [centerX + x, centerY + y],
          [centerX + y, centerY + x],
          [centerX - y, centerY + x],
          [centerX - x, centerY + y],
          [centerX - x, centerY - y],
          [centerX - y, centerY - x],
          [centerX + y, centerY - x],
          [centerX + x, centerY - y],
        ] as const) {
          this.plot(plotX, plotY, color, state);
        }
      }
      y += 1;
      if (error < 0) {
        error += 2 * y + 1;
      } else {
        x -= 1;
        error += 2 * (y - x) + 1;
      }
    }
  }

  private triangle(
    x0: number,
    y0: number,
    x1: number,
    y1: number,
    x2: number,
    y2: number,
    color: number,
    state: DrawState,
  ): void {
    const minimumX = Math.min(x0, x1, x2);
    const maximumX = Math.max(x0, x1, x2);
    const minimumY = Math.min(y0, y1, y2);
    const maximumY = Math.max(y0, y1, y2);
    const area = edge(x0, y0, x1, y1, x2, y2);
    if (area === 0) {
      this.line(x0, y0, x1, y1, color, state);
      this.line(x1, y1, x2, y2, color, state);
      return;
    }
    for (let y = minimumY; y <= maximumY; y += 1) {
      for (let x = minimumX; x <= maximumX; x += 1) {
        const first = edge(x1, y1, x2, y2, x, y);
        const second = edge(x2, y2, x0, y0, x, y);
        const third = edge(x0, y0, x1, y1, x, y);
        if (
          (area > 0 && first >= 0 && second >= 0 && third >= 0) ||
          (area < 0 && first <= 0 && second <= 0 && third <= 0)
        ) {
          this.plot(x, y, color, state);
        }
      }
    }
  }

  private drawSprite(name: string, x: number, y: number, state: DrawState): void {
    const asset = this.assets.get(name);
    if (asset?.kind !== 'sprite') {
      throw new TypeError(`missing Sprite asset '${name}'`);
    }
    this.blit(asset, x, y, 1, 0, false, false, state);
  }

  private drawAnimation(name: string, frame: number, x: number, y: number, state: DrawState): void {
    const asset = this.assets.get(name);
    if (asset?.kind !== 'animation' || asset.frames.length === 0) {
      throw new TypeError(`missing Animation asset '${name}'`);
    }
    const selected = asset.frames[wrap(frame, asset.frames.length)];
    if (selected !== undefined) {
      this.blit(selected, x, y, 1, 0, false, false, state);
    }
  }

  private drawTransformedSprite(
    name: string,
    x: number,
    y: number,
    scale: number,
    quarterTurns: number,
    flipX: boolean,
    flipY: boolean,
    state: DrawState,
  ): void {
    const asset = this.assets.get(name);
    if (asset?.kind !== 'sprite') {
      throw new TypeError(`missing Sprite asset '${name}'`);
    }
    if (scale < 1 || scale > 16) {
      throw new RangeError('sprite scale must be between 1 and 16');
    }
    this.blit(asset, x, y, scale, wrap(quarterTurns, 4), flipX, flipY, state);
  }

  private blit(
    sprite: IndexedSprite,
    x: number,
    y: number,
    scale: number,
    quarterTurns: number,
    flipX: boolean,
    flipY: boolean,
    state: DrawState,
  ): void {
    const outputWidth = (quarterTurns % 2 === 0 ? sprite.width : sprite.height) * scale;
    const outputHeight = (quarterTurns % 2 === 0 ? sprite.height : sprite.width) * scale;
    for (let outputY = 0; outputY < outputHeight; outputY += 1) {
      for (let outputX = 0; outputX < outputWidth; outputX += 1) {
        let sourceX = Math.floor(outputX / scale);
        let sourceY = Math.floor(outputY / scale);
        [sourceX, sourceY] = unrotate(sourceX, sourceY, sprite.width, sprite.height, quarterTurns);
        if (flipX) {
          sourceX = sprite.width - 1 - sourceX;
        }
        if (flipY) {
          sourceY = sprite.height - 1 - sourceY;
        }
        const color = sprite.pixels[sourceY * sprite.width + sourceX] ?? HARDWARE.transparentColor;
        if (color !== HARDWARE.transparentColor) {
          this.plot(x + outputX, y + outputY, color, state);
        }
      }
    }
  }

  private drawMap(name: string, x: number, y: number, state: DrawState): void {
    const map = this.assets.get(name);
    if (map?.kind !== 'map') {
      throw new TypeError(`missing Map asset '${name}'`);
    }
    for (const layer of map.layers) {
      const tileSet = this.assets.get(layer.tileSet);
      if (tileSet?.kind !== 'tile_set') {
        throw new TypeError(`missing TileSet asset '${layer.tileSet}'`);
      }
      for (let row = 0; row < layer.height; row += 1) {
        for (let column = 0; column < layer.width; column += 1) {
          const tile = tileSet.tiles[layer.cells[row * layer.width + column] ?? -1];
          if (tile !== undefined) {
            this.blit(
              tile,
              x + column * HARDWARE.tileSize,
              y + row * HARDWARE.tileSize,
              1,
              0,
              false,
              false,
              state,
            );
          }
        }
      }
    }
  }

  private print(text: string, x: number, y: number, color: number, state: DrawState): void {
    let cursorX = x;
    let cursorY = y;
    for (const character of text) {
      if (character === '\n') {
        cursorX = x;
        cursorY += BITMAP_FONT.advanceY;
        continue;
      }
      const rows = glyphRows(character);
      rows.forEach((bits, row) => {
        for (let column = 0; column < BITMAP_FONT.glyphWidth; column += 1) {
          if ((bits & (1 << (BITMAP_FONT.glyphWidth - 1 - column))) !== 0) {
            this.plot(cursorX + column, cursorY + row, color, state);
          }
        }
      });
      cursorX += BITMAP_FONT.advanceX;
    }
  }
}

/** WebGL2 palette resolver. The GPU sees only indexed pixels and the immutable RGB table. */
export class WebGlIndexedRenderer {
  private readonly gl: WebGL2RenderingContext;
  private readonly program: WebGLProgram;
  private readonly indexTexture: WebGLTexture;
  private readonly paletteTexture: WebGLTexture;
  private readonly vertexArray: WebGLVertexArrayObject;

  public constructor(canvas: HTMLCanvasElement) {
    canvas.width = HARDWARE.width;
    canvas.height = HARDWARE.height;
    const gl = canvas.getContext('webgl2', { alpha: false, antialias: false, depth: false });
    if (gl === null) {
      throw new Error('WebGL2 is required by the PX-240C alpha renderer');
    }
    this.gl = gl;
    this.program = createProgram(gl);
    this.indexTexture = requireObject(gl.createTexture(), 'index texture');
    this.paletteTexture = requireObject(gl.createTexture(), 'palette texture');
    this.vertexArray = requireObject(gl.createVertexArray(), 'vertex array');
    gl.bindVertexArray(this.vertexArray);
    gl.useProgram(this.program);
    configureIndexTexture(gl, this.indexTexture);
    configurePaletteTexture(gl, this.paletteTexture);
    setSampler(gl, this.program, 'indexedFrame', 0);
    setSampler(gl, this.program, 'masterPalette', 1);
    gl.viewport(0, 0, HARDWARE.width, HARDWARE.height);
  }

  public render(indexedPixels: Uint8Array): void {
    if (indexedPixels.length !== HARDWARE.width * HARDWARE.height) {
      throw new RangeError('indexed frame has the wrong dimensions');
    }
    const gl = this.gl;
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.indexTexture);
    gl.texSubImage2D(
      gl.TEXTURE_2D,
      0,
      0,
      0,
      HARDWARE.width,
      HARDWARE.height,
      gl.RED_INTEGER,
      gl.UNSIGNED_BYTE,
      indexedPixels,
    );
    gl.bindVertexArray(this.vertexArray);
    gl.useProgram(this.program);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  public destroy(): void {
    this.gl.deleteTexture(this.indexTexture);
    this.gl.deleteTexture(this.paletteTexture);
    this.gl.deleteVertexArray(this.vertexArray);
    this.gl.deleteProgram(this.program);
  }
}

/** Deterministic four-by-four Bayer choice between two palette indices. */
export function orderedDither(
  x: number,
  y: number,
  first: number,
  second: number,
  level: number,
): number {
  const matrix = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5] as const;
  const threshold = matrix[wrap(y, 4) * 4 + wrap(x, 4)] ?? 0;
  return threshold < Math.max(0, Math.min(16, level)) ? expectColor(second) : expectColor(first);
}

function initialDrawState(remap = identityRemap()): DrawState {
  return {
    cameraX: 0,
    cameraY: 0,
    clipX: 0,
    clipY: 0,
    clipWidth: HARDWARE.width,
    clipHeight: HARDWARE.height,
    remap: remap.slice(),
  };
}

function copyDisplayConfiguration(display?: DisplayConfiguration): DisplayConfiguration {
  if (display === undefined) {
    return { remap: identityRemap(), raster: [] };
  }
  if (!validRemap(display.remap)) {
    throw new TypeError('display configuration has an invalid base remap');
  }
  let previousLine = -1;
  const raster = display.raster.map((state) => {
    if (
      !Number.isInteger(state.line) ||
      state.line <= previousLine ||
      state.line >= HARDWARE.height ||
      !Number.isSafeInteger(state.scrollX) ||
      !Number.isSafeInteger(state.scrollY) ||
      state.scrollX < -32_768 ||
      state.scrollX > 32_767 ||
      state.scrollY < -32_768 ||
      state.scrollY > 32_767 ||
      !validRemap(state.remap)
    ) {
      throw new TypeError('display configuration has invalid raster state');
    }
    previousLine = state.line;
    return { ...state, remap: state.remap.slice() };
  });
  return { remap: display.remap.slice(), raster };
}

function validRemap(remap: Uint8Array): boolean {
  return (
    remap.length === HARDWARE.paletteSize && remap.every((color) => color < HARDWARE.paletteSize)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function identityRemap(): Uint8Array {
  return Uint8Array.from({ length: HARDWARE.paletteSize }, (_, index) => index);
}

function validateAsset(asset: VisualAsset): void {
  if (asset.name.length === 0) {
    throw new TypeError('visual asset names cannot be empty');
  }
  switch (asset.kind) {
    case 'sprite':
      validateSprite(asset);
      return;
    case 'animation':
      if (asset.frames.length === 0) {
        throw new RangeError(`animation '${asset.name}' has no frames`);
      }
      asset.frames.forEach(validateSprite);
      return;
    case 'tile_set':
      if (asset.tiles.length === 0 || asset.flags.length !== asset.tiles.length) {
        throw new RangeError(`tile set '${asset.name}' has incoherent tiles or flags`);
      }
      for (const tile of asset.tiles) {
        validateSprite(tile);
        if (tile.width !== HARDWARE.tileSize || tile.height !== HARDWARE.tileSize) {
          throw new RangeError(`tile set '${asset.name}' contains a non-8x8 tile`);
        }
      }
      return;
    case 'map':
      if (asset.layers.length === 0) {
        throw new RangeError(`map '${asset.name}' has no layers`);
      }
      for (const layer of asset.layers) {
        if (
          !Number.isSafeInteger(layer.width) ||
          !Number.isSafeInteger(layer.height) ||
          layer.width <= 0 ||
          layer.height <= 0 ||
          layer.cells.length !== layer.width * layer.height ||
          layer.tileSet.length === 0
        ) {
          throw new RangeError(`map '${asset.name}' has an invalid layer`);
        }
      }
  }
}

function validateSprite(sprite: IndexedSprite): void {
  if (
    !Number.isSafeInteger(sprite.width) ||
    !Number.isSafeInteger(sprite.height) ||
    sprite.width < 1 ||
    sprite.width > HARDWARE.spriteMaximumAxis ||
    sprite.height < 1 ||
    sprite.height > HARDWARE.spriteMaximumAxis ||
    sprite.pixels.length !== sprite.width * sprite.height ||
    sprite.pixels.some((color) => color >= HARDWARE.paletteSize)
  ) {
    throw new RangeError(`sprite '${sprite.name}' is outside PX-240C limits`);
  }
}

export function visualAssetBytes(asset: VisualAsset): number {
  switch (asset.kind) {
    case 'sprite':
      return asset.pixels.byteLength;
    case 'animation':
      return asset.frames.reduce((total, frame) => total + frame.pixels.byteLength, 0);
    case 'tile_set':
      return (
        asset.flags.byteLength +
        asset.tiles.reduce((total, tile) => total + tile.pixels.byteLength, 0)
      );
    case 'map':
      return asset.layers.reduce((total, layer) => total + layer.cells.byteLength, 0);
  }
}

function expectIntegers(command: ConsoleCommand, count: 0): [];
function expectIntegers(command: ConsoleCommand, count: 1): [number];
function expectIntegers(command: ConsoleCommand, count: 2): [number, number];
function expectIntegers(command: ConsoleCommand, count: 3): [number, number, number];
function expectIntegers(command: ConsoleCommand, count: 4): [number, number, number, number];
function expectIntegers(
  command: ConsoleCommand,
  count: 5,
): [number, number, number, number, number];
function expectIntegers(
  command: ConsoleCommand,
  count: 7,
): [number, number, number, number, number, number, number];
function expectIntegers(command: ConsoleCommand, count: number): number[] {
  if (command.arguments.length !== count) {
    throw new TypeError(
      `${command.name} expected ${String(count)} arguments, received ${String(command.arguments.length)}`,
    );
  }
  return command.arguments.map(expectInteger);
}

function expectInteger(value: unknown): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) {
    throw new TypeError('graphics arguments must be safe integers');
  }
  return value;
}

function expectBoolean(value: unknown): boolean {
  if (typeof value !== 'boolean') {
    throw new TypeError('graphics argument must be Bool');
  }
  return value;
}

function expectText(value: unknown): string {
  if (typeof value !== 'string') {
    throw new TypeError('graphics argument must be Text');
  }
  return value;
}

function expectColor(value: number): number {
  if (value < 0 || value >= HARDWARE.paletteSize) {
    throw new RangeError('palette index must be between 0 and 31');
  }
  return value;
}

function readAssetName(value: unknown, expectedKind: string): string {
  if (
    typeof value !== 'object' ||
    value === null ||
    !('name' in value) ||
    typeof value.name !== 'string' ||
    !('kind' in value) ||
    value.kind !== expectedKind
  ) {
    throw new TypeError(`expected a ${expectedKind} asset handle`);
  }
  return value.name;
}

function edge(
  firstX: number,
  firstY: number,
  secondX: number,
  secondY: number,
  pointX: number,
  pointY: number,
): number {
  return (pointX - firstX) * (secondY - firstY) - (pointY - firstY) * (secondX - firstX);
}

function unrotate(
  x: number,
  y: number,
  width: number,
  height: number,
  quarterTurns: number,
): [number, number] {
  switch (quarterTurns) {
    case 1:
      return [y, height - 1 - x];
    case 2:
      return [width - 1 - x, height - 1 - y];
    case 3:
      return [width - 1 - y, x];
    default:
      return [x, y];
  }
}

function wrap(value: number, modulus: number): number {
  return ((value % modulus) + modulus) % modulus;
}

function clampInt16(value: number): number {
  return Math.max(-32_768, Math.min(32_767, value));
}

function createProgram(gl: WebGL2RenderingContext): WebGLProgram {
  const vertex = compileShader(
    gl,
    gl.VERTEX_SHADER,
    `#version 300 es
    const vec2 positions[3] = vec2[3](vec2(-1.0,-1.0),vec2(3.0,-1.0),vec2(-1.0,3.0));
    void main(){gl_Position=vec4(positions[gl_VertexID],0.0,1.0);}`,
  );
  const fragment = compileShader(
    gl,
    gl.FRAGMENT_SHADER,
    `#version 300 es
    precision highp float;
    precision highp usampler2D;
    uniform usampler2D indexedFrame;
    uniform sampler2D masterPalette;
    out vec4 color;
    void main(){
      ivec2 point=ivec2(int(gl_FragCoord.x),${String(HARDWARE.height - 1)}-int(gl_FragCoord.y));
      uint index=texelFetch(indexedFrame,point,0).r;
      color=texelFetch(masterPalette,ivec2(int(index),0),0);
    }`,
  );
  const program = requireObject(gl.createProgram(), 'shader program');
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.linkProgram(program);
  gl.deleteShader(vertex);
  gl.deleteShader(fragment);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(`WebGL2 link failed: ${gl.getProgramInfoLog(program) ?? 'unknown error'}`);
  }
  return program;
}

function compileShader(gl: WebGL2RenderingContext, type: number, source: string): WebGLShader {
  const shader = requireObject(gl.createShader(type), 'shader');
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    throw new Error(`WebGL2 shader failed: ${gl.getShaderInfoLog(shader) ?? 'unknown error'}`);
  }
  return shader;
}

function configureIndexTexture(gl: WebGL2RenderingContext, texture: WebGLTexture): void {
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texImage2D(
    gl.TEXTURE_2D,
    0,
    gl.R8UI,
    HARDWARE.width,
    HARDWARE.height,
    0,
    gl.RED_INTEGER,
    gl.UNSIGNED_BYTE,
    null,
  );
}

function configurePaletteTexture(gl: WebGL2RenderingContext, texture: WebGLTexture): void {
  gl.activeTexture(gl.TEXTURE1);
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texImage2D(
    gl.TEXTURE_2D,
    0,
    gl.RGBA8,
    HARDWARE.paletteSize,
    1,
    0,
    gl.RGBA,
    gl.UNSIGNED_BYTE,
    Uint8Array.from(MASTER_PALETTE_RGBA),
  );
}

function setSampler(
  gl: WebGL2RenderingContext,
  program: WebGLProgram,
  name: string,
  unit: number,
): void {
  const location = gl.getUniformLocation(program, name);
  if (location === null) {
    throw new Error(`WebGL2 sampler '${name}' is missing`);
  }
  gl.uniform1i(location, unit);
}

function requireObject<Value>(value: Value | null, description: string): Value {
  if (value === null) {
    throw new Error(`WebGL2 could not create ${description}`);
  }
  return value;
}
