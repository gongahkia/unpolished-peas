import { AudioAssetStore, type AudioAsset, type MusicAsset, type SoundAsset } from './audio';
import {
  VisualAssetStore,
  type IndexedAnimation,
  type IndexedMap,
  type IndexedSprite,
  type IndexedTileSet,
  type VisualAsset,
} from './graphics';
import type { MapQueryAsset } from './map-query';

export type ProjectAssetKind =
  'sprite' | 'animation' | 'tile_set' | 'map' | 'font' | 'sound' | 'music';

export interface ProjectAssetDeclaration {
  readonly kind: ProjectAssetKind;
  readonly path: string;
}

export interface RuntimeAssetBundle {
  readonly visual: readonly VisualAsset[];
  readonly audio: readonly AudioAsset[];
  readonly maps: readonly MapQueryAsset[];
  readonly visualBytes: number;
}

export interface SpriteAssetFile {
  readonly revision: 1;
  readonly kind: 'sprite';
  readonly width: number;
  readonly height: number;
  readonly frames: readonly (readonly number[])[];
}

export interface TileSetAssetFile {
  readonly revision: 1;
  readonly kind: 'tile_set';
  readonly tiles: readonly (readonly number[])[];
  readonly flags: readonly number[];
}

export interface MapAssetFile {
  readonly revision: 1;
  readonly kind: 'map';
  readonly layers: readonly {
    readonly width: number;
    readonly height: number;
    readonly cells: readonly number[];
    readonly tileSet: string;
  }[];
}

/** Decodes documented JSON asset files into validated hardware stores and worker map views. */
export function decodeRuntimeAssets(
  declarations: Readonly<Record<string, ProjectAssetDeclaration>>,
  files: Readonly<Record<string, Uint8Array>>,
): RuntimeAssetBundle {
  const visual: VisualAsset[] = [];
  const audio: AudioAsset[] = [];
  for (const [name, declaration] of Object.entries(declarations).sort(([left], [right]) =>
    left.localeCompare(right),
  )) {
    const bytes = files[declaration.path];
    if (bytes === undefined) {
      throw new TypeError(`asset '${name}' is missing '${declaration.path}'`);
    }
    const value: unknown = JSON.parse(new TextDecoder().decode(bytes));
    switch (declaration.kind) {
      case 'sprite':
        visual.push(decodeSprite(name, value, false));
        break;
      case 'animation':
        visual.push(decodeSprite(name, value, true));
        break;
      case 'tile_set':
        visual.push(decodeTileSet(name, value));
        break;
      case 'map':
        visual.push(decodeMap(name, value));
        break;
      case 'sound':
        audio.push(decodeSound(name, value));
        break;
      case 'music':
        audio.push(decodeMusic(name, value));
        break;
      case 'font':
        throw new TypeError(`custom font asset '${name}' is not implemented in revision 1`);
    }
  }
  const visualStore = new VisualAssetStore(visual);
  new AudioAssetStore(audio);
  const tileSets = new Map(
    visual
      .filter((asset): asset is IndexedTileSet => asset.kind === 'tile_set')
      .map((asset) => [asset.name, asset]),
  );
  const maps = visual
    .filter((asset): asset is IndexedMap => asset.kind === 'map')
    .map((asset) => ({
      name: asset.name,
      layers: asset.layers.map((layer) => {
        const tileSet = tileSets.get(layer.tileSet);
        if (tileSet === undefined) {
          throw new TypeError(`map '${asset.name}' references missing tile set '${layer.tileSet}'`);
        }
        return {
          width: layer.width,
          height: layer.height,
          cells: layer.cells.slice(),
          tileFlags: tileSet.flags.slice(),
        };
      }),
    }));
  return {
    visual,
    audio,
    maps,
    visualBytes: visualStore.usedBytes,
  };
}

export function encodeAssetFile(value: unknown): Uint8Array {
  return new TextEncoder().encode(`${JSON.stringify(value)}\n`);
}

export function encodeSoundAssetFile(asset: SoundAsset): Uint8Array {
  return encodeAssetFile({ ...asset, name: undefined, revision: 1 });
}

export function encodeMusicAssetFile(asset: MusicAsset): Uint8Array {
  return encodeAssetFile({ ...asset, name: undefined, revision: 1 });
}

function decodeSprite(
  name: string,
  value: unknown,
  animation: boolean,
): IndexedSprite | IndexedAnimation {
  if (
    !isRecord(value) ||
    value.revision !== 1 ||
    value.kind !== 'sprite' ||
    !boundedInteger(value.width, 1, 64) ||
    !boundedInteger(value.height, 1, 64) ||
    !Array.isArray(value.frames) ||
    value.frames.length === 0 ||
    value.frames.length > 256
  ) {
    throw new TypeError(`sprite asset '${name}' is invalid`);
  }
  const pixelCount = value.width * value.height;
  const frames = value.frames.map((frame) => {
    if (!isNumberArray(frame, pixelCount, 0, 31)) {
      throw new TypeError(`sprite asset '${name}' has invalid indexed pixels`);
    }
    return {
      kind: 'sprite' as const,
      name,
      width: value.width as number,
      height: value.height as number,
      pixels: Uint8Array.from(frame),
    };
  });
  const first = frames[0];
  if (first === undefined) {
    throw new TypeError(`sprite asset '${name}' requires a frame`);
  }
  return animation ? { kind: 'animation', name, frames } : { ...first, name };
}

function decodeTileSet(name: string, value: unknown): IndexedTileSet {
  if (
    !isRecord(value) ||
    value.revision !== 1 ||
    value.kind !== 'tile_set' ||
    !Array.isArray(value.tiles) ||
    value.tiles.length === 0 ||
    value.tiles.length > 4096 ||
    !isNumberArray(value.flags, value.tiles.length, 0, 255)
  ) {
    throw new TypeError(`tile-set asset '${name}' is invalid`);
  }
  const tiles = value.tiles.map((pixels, index) => {
    if (!isNumberArray(pixels, 64, 0, 31)) {
      throw new TypeError(`tile ${String(index)} in '${name}' has invalid indexed pixels`);
    }
    return {
      kind: 'sprite' as const,
      name: `${name}:${String(index)}`,
      width: 8,
      height: 8,
      pixels: Uint8Array.from(pixels),
    };
  });
  return { kind: 'tile_set', name, tiles, flags: Uint8Array.from(value.flags) };
}

function decodeMap(name: string, value: unknown): IndexedMap {
  if (
    !isRecord(value) ||
    value.revision !== 1 ||
    value.kind !== 'map' ||
    !Array.isArray(value.layers) ||
    value.layers.length === 0 ||
    value.layers.length > 8
  ) {
    throw new TypeError(`map asset '${name}' is invalid`);
  }
  const layers = value.layers.map((layer) => {
    if (
      !isRecord(layer) ||
      !boundedInteger(layer.width, 1, 256) ||
      !boundedInteger(layer.height, 1, 256) ||
      typeof layer.tileSet !== 'string' ||
      !isNumberArray(layer.cells, layer.width * layer.height, 0, 65_535)
    ) {
      throw new TypeError(`map asset '${name}' has an invalid layer`);
    }
    return {
      width: layer.width,
      height: layer.height,
      cells: Uint16Array.from(layer.cells),
      tileSet: layer.tileSet,
    };
  });
  return { kind: 'map', name, layers };
}

function decodeSound(name: string, value: unknown): SoundAsset {
  if (!isRecord(value) || value.revision !== 1 || value.kind !== 'sound') {
    throw new TypeError(`sound asset '${name}' is invalid`);
  }
  const sound = { ...value, name } as unknown as SoundAsset;
  new AudioAssetStore([sound]);
  return sound;
}

function decodeMusic(name: string, value: unknown): MusicAsset {
  if (!isRecord(value) || value.revision !== 1 || value.kind !== 'music') {
    throw new TypeError(`music asset '${name}' is invalid`);
  }
  return { ...value, name } as unknown as MusicAsset;
}

function isNumberArray(
  value: unknown,
  length: number,
  minimum: number,
  maximum: number,
): value is number[] {
  return (
    Array.isArray(value) &&
    value.length === length &&
    value.every((entry) => Number.isSafeInteger(entry) && entry >= minimum && entry <= maximum)
  );
}

function boundedInteger(value: unknown, minimum: number, maximum: number): value is number {
  return (
    Number.isSafeInteger(value) && typeof value === 'number' && value >= minimum && value <= maximum
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
