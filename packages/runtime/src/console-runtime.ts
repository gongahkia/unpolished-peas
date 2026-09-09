import { RuntimeFault } from './errors';
import {
  DeterministicMachine,
  isMachineSnapshot,
  type CartridgeFactory,
  type ExecutionContext,
  type MachineSnapshot,
} from './machine';
import { decodeRuntimeAssets, isRuntimeAssetSource } from './asset-codec';
import { AudioAssetStore, Synthesizer, isSynthSnapshot, type SynthSnapshot } from './audio';
import {
  IndexedGraphics,
  VisualAssetStore,
  isGraphicsSnapshot,
  type GraphicsSnapshot,
} from './graphics';
import { HARDWARE } from './hardware';
import { MapQueryStore } from './map-query';
import {
  SaveMemory,
  isSaveValues,
  isPendingSaveWrites,
  type SaveValues,
  type SaveWrite,
} from './save';
import type { InputFrame } from './input';
import type {
  ConsoleCommand,
  DebugStackFrame,
  DebugTraceEvent,
  SandboxConfiguration,
  SourceSpan,
  WorkerResponse,
} from './protocol';

export type ConsoleFrame = Omit<Extract<WorkerResponse, { type: 'frame' }>, 'id' | 'type'>;

export interface ConsoleRuntime {
  runFrame(input: InputFrame): ConsoleFrame;
  snapshot(): ConsoleRuntimeSnapshot;
  restore(snapshot: unknown): void;
}

export interface ConsoleRuntimeSnapshot {
  readonly revision: 2;
  readonly machine: MachineSnapshot;
  readonly save: SaveValues;
  readonly graphics: GraphicsSnapshot;
  readonly audio: SynthSnapshot;
  readonly pendingSaveWrites: readonly SaveWrite[];
}

export function isConsoleRuntimeSnapshot(value: unknown): value is ConsoleRuntimeSnapshot {
  return (
    isRecord(value) &&
    value.revision === 2 &&
    Object.keys(value).length === 6 &&
    isMachineSnapshot(value.machine) &&
    isSaveValues(value.save) &&
    isGraphicsSnapshot(value.graphics) &&
    isSynthSnapshot(value.audio) &&
    isPendingSaveWrites(value.pendingSaveWrites, value.save)
  );
}

/** One production dispatcher for restricted Workers and deterministic headless hosts. */
export function createConsoleRuntime(
  factory: CartridgeFactory,
  configuration: SandboxConfiguration,
): ConsoleRuntime {
  if (configuration.assets !== undefined && !isRuntimeAssetSource(configuration.assets))
    throw new RuntimeFault('PX9100', 'invalid runtime asset source', { start: 0, end: 0 });
  const source = configuration.assets;
  const assets =
    source === undefined
      ? decodeRuntimeAssets({}, {})
      : decodeRuntimeAssets(source.declarations, source.files, source.displayPath);
  const visualStore = new VisualAssetStore(assets.visual);
  const graphics = new IndexedGraphics(visualStore, assets.display);
  const synthesizer = new Synthesizer(new AudioAssetStore(assets.audio));
  let rendering = false;
  let machine: DeterministicMachine | undefined = undefined;
  let drawCommands: ConsoleCommand[] = [];
  let audioCommands: ConsoleCommand[] = [];
  const mapQueries = new MapQueryStore(source === undefined ? (configuration.maps ?? []) : []);
  const saveMemory = new SaveMemory(configuration.save ?? {});
  const debugEnabled = configuration.debug ?? false;
  let debugTrace: DebugTraceEvent[] = [];
  const debugCallStack: DebugStackFrame[] = [];
  let debugTraceTruncated = false;

  machine = new DeterministicMachine(factory, configuration, {
    call: handleConsoleCall,
    ...(debugEnabled
      ? {
          probe: (id: number, sourceSpan: SourceSpan, locals: unknown) => {
            if (debugTrace.length >= HARDWARE.drawCommandsPerFrame) {
              debugTraceTruncated = true;
              return;
            }
            debugTrace.push({
              id,
              sourceSpan,
              locals: structuredClone(locals),
              callStack: structuredClone(debugCallStack),
            });
          },
          enter: (name: string, sourceSpan: SourceSpan) => {
            debugCallStack.push({ name, sourceSpan });
          },
          leave: () => {
            debugCallStack.pop();
          },
        }
      : {}),
  });
  machine.boot();

  return {
    runFrame(input) {
      drawCommands = [];
      audioCommands = [];
      debugTrace = [];
      debugTraceTruncated = false;
      const active = requireMachine();
      graphics.beginFrame();
      rendering = true;
      let report;
      try {
        report = active.runFrame(input);
      } finally {
        rendering = false;
      }
      const output = {
        indexedPixels: graphics.finishFrame().indexedPixels,
        audio: synthesizer.finishFrame(),
        audioState: synthesizer.snapshot(),
      };
      return {
        ...report,
        drawCommands,
        audioCommands,
        saveWrites: saveMemory.takeWrites(),
        output,
        ...(debugEnabled
          ? {
              debug: {
                trace: debugTrace,
                truncated: debugTraceTruncated,
                inspection: structuredClone(active.inspect()),
              },
            }
          : {}),
      };
    },
    snapshot: captureSnapshot,
    restore(value) {
      const snapshot = readWorkerSnapshot(value);
      const before = captureSnapshot();
      try {
        requireMachine().restore(snapshot.machine);
        saveMemory.restore(snapshot.save, snapshot.pendingSaveWrites);
        if (snapshot.revision === 2) {
          graphics.restore(snapshot.graphics);
          synthesizer.restore(snapshot.audio);
        }
      } catch (error) {
        requireMachine().restore(before.machine);
        saveMemory.restore(before.save, before.pendingSaveWrites);
        graphics.restore(before.graphics);
        synthesizer.restore(before.audio);
        throw new RuntimeFault(
          'PX9103',
          error instanceof Error ? error.message : 'invalid device snapshot',
          { start: 0, end: 0 },
        );
      }
    },
  };

  function captureSnapshot(): ConsoleRuntimeSnapshot {
    return {
      revision: 2,
      machine: requireMachine().snapshot(),
      save: saveMemory.snapshot(),
      graphics: graphics.snapshot(),
      audio: synthesizer.snapshot(),
      pendingSaveWrites: saveMemory.pendingWrites(),
    };
  }

  function handleConsoleCall(
    name: string,
    arguments_: readonly unknown[],
    sourceSpan: SourceSpan,
    context: ExecutionContext,
  ): unknown {
    requireMachine().work(consoleWorkCost(name, arguments_), sourceSpan);
    if (context.phase === 'raster' && name !== 'pal' && name !== 'raster_scroll') {
      throw new RuntimeFault(
        'PX9011',
        `console API call '${name}' is not valid in the raster callback`,
        sourceSpan,
      );
    }
    if (name === 'raster_scroll' && context.phase !== 'raster') {
      throw new RuntimeFault(
        'PX9011',
        'raster_scroll is only valid in the raster callback',
        sourceSpan,
      );
    }
    if (name === 'map_cell' || name === 'map_flag') {
      const handle = arguments_[0];
      if (!isAssetHandle(handle, 'Map')) {
        throw new RuntimeFault('PX9009', 'expected a Map asset handle', sourceSpan);
      }
      const integers = arguments_.slice(1).map((value) => readInteger(value, sourceSpan));
      if (name === 'map_cell' && integers.length === 3) {
        if (source !== undefined)
          return (
            visualStore.mapCell(
              handle.name,
              integers[0] ?? 0,
              integers[1] ?? 0,
              integers[2] ?? 0,
            ) ?? -1
          );
        return mapQueries.cell(handle.name, integers[0] ?? 0, integers[1] ?? 0, integers[2] ?? 0);
      }
      if (name === 'map_flag' && integers.length === 4) {
        if (source !== undefined)
          return visualStore.mapFlag(
            handle.name,
            integers[0] ?? 0,
            integers[1] ?? 0,
            integers[2] ?? 0,
            integers[3] ?? 0,
          );
        return mapQueries.flag(
          handle.name,
          integers[0] ?? 0,
          integers[1] ?? 0,
          integers[2] ?? 0,
          integers[3] ?? 0,
        );
      }
      throw new RuntimeFault('PX9009', `${name} received the wrong argument count`, sourceSpan);
    }
    if (name === 'save_get_int' || name === 'save_set_int') {
      const key = arguments_[0];
      if (typeof key !== 'string') {
        throw new RuntimeFault('PX9009', 'save key must be Text', sourceSpan);
      }
      try {
        if (name === 'save_get_int' && arguments_.length === 2) {
          return saveMemory.get(key, readInteger(arguments_[1], sourceSpan));
        }
        if (name === 'save_set_int' && arguments_.length === 2) {
          saveMemory.set(key, readInteger(arguments_[1], sourceSpan));
          return undefined;
        }
      } catch (error: unknown) {
        throw new RuntimeFault(
          'PX9012',
          error instanceof Error ? error.message : 'invalid cartridge save operation',
          sourceSpan,
        );
      }
      throw new RuntimeFault('PX9009', `${name} received the wrong argument count`, sourceSpan);
    }
    const command = {
      name,
      arguments: structuredClone(arguments_),
      sourceSpan,
      ...(context.rasterLine === undefined ? {} : { rasterLine: context.rasterLine }),
    };
    if (DRAW_CALLS.has(name)) {
      if (drawCommands.length >= HARDWARE.drawCommandsPerFrame) {
        throw new RuntimeFault('PX9010', 'draw-command ceiling exceeded', sourceSpan);
      }
      drawCommands.push(command);
      if (rendering) graphics.executeCommand(command);
      return undefined;
    }
    if (AUDIO_CALLS.has(name)) {
      audioCommands.push(command);
      if (rendering) synthesizer.executeCommand(command);
      return undefined;
    }
    throw new RuntimeFault('PX9004', `console API call '${name}' is unavailable`, sourceSpan);
  }

  function requireMachine(): DeterministicMachine {
    if (machine === undefined) {
      throw new RuntimeFault('PX9102', 'no cartridge is loaded', { start: 0, end: 0 });
    }
    return machine;
  }
}

const DRAW_CALLS = new Set([
  'clear',
  'pixel',
  'line',
  'rect',
  'rect_fill',
  'circle',
  'circle_fill',
  'triangle',
  'camera',
  'clip',
  'clip_reset',
  'sprite',
  'sprite_xform',
  'animation',
  'map',
  'pal',
  'pal_reset',
  'raster_scroll',
  'print',
]);

const AUDIO_CALLS = new Set(['sfx', 'music', 'music_stop']);

export function consoleWorkCost(name: string, arguments_: readonly unknown[]): number {
  const integer = (index: number): number => {
    const value = arguments_[index];
    return typeof value === 'number' && Number.isSafeInteger(value) ? value : 0;
  };
  switch (name) {
    case 'clear':
      return Math.ceil((HARDWARE.width * HARDWARE.height) / 32);
    case 'pixel':
      return 1;
    case 'line':
      return Math.max(Math.abs(integer(2) - integer(0)), Math.abs(integer(3) - integer(1))) + 1;
    case 'rect':
      return Math.max(1, 2 * Math.abs(integer(2)) + 2 * Math.abs(integer(3)));
    case 'rect_fill':
      return Math.max(1, Math.ceil((Math.abs(integer(2)) * Math.abs(integer(3))) / 4));
    case 'circle':
      return Math.max(1, Math.abs(integer(2)) * 8);
    case 'circle_fill':
      return Math.max(1, Math.ceil((Math.abs(integer(2)) ** 2 * 3) / 4));
    case 'triangle': {
      const area = Math.abs(
        (integer(2) - integer(0)) * (integer(5) - integer(1)) -
          (integer(4) - integer(0)) * (integer(3) - integer(1)),
      );
      return Math.max(1, Math.ceil(area / 8));
    }
    case 'sprite':
    case 'animation':
      return 32;
    case 'sprite_xform':
      return Math.max(32, 32 * Math.abs(integer(3)) ** 2);
    case 'map':
      return 128;
    case 'print':
      return Math.max(1, (typeof arguments_[0] === 'string' ? arguments_[0].length : 0) * 6);
    case 'sfx':
    case 'music':
    case 'music_stop':
      return 8;
    default:
      return 1;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isAssetHandle(value: unknown, kind: string): value is { name: string; kind: string } {
  return (
    isRecord(value) &&
    typeof value.name === 'string' &&
    value.name.length > 0 &&
    value.kind === kind
  );
}

function readInteger(value: unknown, sourceSpan: SourceSpan): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) {
    throw new RuntimeFault('PX9009', 'map query arguments must be safe integers', sourceSpan);
  }
  return value;
}

function readWorkerSnapshot(value: unknown): {
  revision: 1 | 2;
  machine: unknown;
  save: SaveValues;
  graphics: unknown;
  audio: unknown;
  pendingSaveWrites: readonly SaveWrite[];
} {
  if (
    !isRecord(value) ||
    (value.revision === 2
      ? !isConsoleRuntimeSnapshot(value)
      : value.revision !== 1 || !isMachineSnapshot(value.machine) || !isSaveValues(value.save))
  ) {
    throw new RuntimeFault('PX9103', 'invalid worker snapshot', { start: 0, end: 0 });
  }
  return {
    revision: value.revision === 2 ? 2 : 1,
    machine: value.machine,
    save: value.save as SaveValues,
    graphics: value.graphics,
    audio: value.audio,
    pendingSaveWrites:
      value.revision === 2 ? (value.pendingSaveWrites as readonly SaveWrite[]) : [],
  };
}
