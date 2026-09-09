import { RuntimeFault } from './errors';
import {
  DeterministicMachine,
  isMachineSnapshot,
  type CartridgeFactory,
  type ExecutionContext,
  type MachineSnapshot,
} from './machine';
import { decodeRuntimeAssets } from './asset-codec';
import { AudioAssetStore, Synthesizer, isSynthSnapshot, type SynthSnapshot } from './audio';
import {
  IndexedGraphics,
  VisualAssetStore,
  isGraphicsSnapshot,
  type GraphicsSnapshot,
} from './graphics';
import { HARDWARE, MASTER_PALETTE_RGBA } from './hardware';
import { MEMORY, MemoryBus, isMemorySnapshot, type MemorySnapshot } from './bus';
import { MapQueryStore } from './map-query';
import {
  SaveMemory,
  isSaveValues,
  isPendingSaveWrites,
  isSaveSnapshot,
  isPendingDeviceWrites,
  type SaveSnapshot,
  type SaveValues,
  type SaveWrite,
} from './save';
import { isInputFrame, type InputFrame } from './input';
import { isSandboxConfiguration } from './protocol';
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
  readonly revision: 6;
  readonly machine: MachineSnapshot;
  readonly save: SaveSnapshot;
  readonly graphics: GraphicsSnapshot;
  readonly audio: SynthSnapshot;
  readonly pendingSaveWrites: readonly SaveWrite[];
  readonly memory: MemorySnapshot;
}

export function isConsoleRuntimeSnapshot(value: unknown): value is ConsoleRuntimeSnapshot {
  return (
    isRecord(value) &&
    value.revision === 6 &&
    Object.keys(value).length === 7 &&
    isMachineSnapshot(value.machine) &&
    value.machine.revision === 2 &&
    isSaveSnapshot(value.save) &&
    isGraphicsSnapshot(value.graphics) &&
    isSynthSnapshot(value.audio) &&
    isPendingDeviceWrites(value.pendingSaveWrites, value.save) &&
    isMemorySnapshot(value.memory) &&
    graphicsMatchesMemory(value.graphics, value.memory)
  );
}

/** One production dispatcher for restricted Workers and deterministic headless hosts. */
export function createConsoleRuntime(
  factory: CartridgeFactory,
  configuration: SandboxConfiguration,
): ConsoleRuntime {
  if (!isSandboxConfiguration(configuration))
    throw new RuntimeFault('PX9100', 'invalid sandbox configuration', { start: 0, end: 0 });
  const source = configuration.assets;
  const assets =
    source === undefined
      ? decodeRuntimeAssets({}, {})
      : decodeRuntimeAssets(source.declarations, source.files, source.displayPath);
  const visualStore = new VisualAssetStore(assets.visual, assets.display);
  const graphics = new IndexedGraphics(visualStore);
  const audioStore = new AudioAssetStore(assets.audio);
  const synthesizer = new Synthesizer(audioStore);
  let rendering = false;
  let machine: DeterministicMachine | undefined = undefined;
  let drawCommands: ConsoleCommand[] = [];
  let audioCommands: ConsoleCommand[] = [];
  let frameOutput: ConsoleFrame['output'] | undefined;
  const mapQueries = new MapQueryStore(source === undefined ? (configuration.maps ?? []) : []);
  const saveMemory = new SaveMemory(configuration.save ?? {});
  const debugEnabled = configuration.debug ?? false;
  let debugTrace: DebugTraceEvent[] = [];
  const debugCallStack: DebugStackFrame[] = [];
  let debugTraceTruncated = false;
  const ram = new Uint8Array(MEMORY.ramBytes);
  const bus = new MemoryBus(
    [
      { name: 'ram', address: MEMORY.ram, bytes: ram, writable: true },
      ...graphics.memoryRegions(),
      ...visualStore.memoryRegions(),
      ...synthesizer.memoryRegions(),
      ...saveMemory.memoryRegions((units, span) => {
        requireMachine().work(units, span);
      }),
      {
        name: 'controllers and pointer',
        address: MEMORY.input,
        length: MEMORY.inputBytes,
        writable: false,
        readByte: (offset) => requireMachine().readInputByte(offset),
      },
      {
        name: 'scheduler, RNG, work and fault status',
        address: MEMORY.system,
        length: MEMORY.systemBytes,
        writable: false,
        readByte: (offset) => requireMachine().readSystemByte(offset),
      },
      {
        name: 'master palette RGBA',
        address: MEMORY.palette,
        bytes: Uint8Array.from(MASTER_PALETTE_RGBA),
        writable: false,
      },
    ],
    (units, span) => {
      requireMachine().work(units, span);
    },
  );

  machine = new DeterministicMachine(factory, configuration, {
    completeFrame: () => {
      frameOutput = {
        indexedPixels: graphics.finishFrame().indexedPixels,
        audio: synthesizer.finishFrame(),
        audioState: synthesizer.snapshot(),
      };
    },
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
  graphics.beginFrame();
  rendering = true;
  try {
    machine.boot();
  } finally {
    rendering = false;
  }
  graphics.finishFrame();

  return {
    runFrame(input) {
      if (!isInputFrame(input))
        throw new RuntimeFault('PX9008', 'invalid controller input frame', { start: 0, end: 0 });
      const active = requireMachine();
      active.assertRunnable();
      drawCommands = [];
      audioCommands = [];
      frameOutput = undefined;
      debugTrace = [];
      debugTraceTruncated = false;
      graphics.beginFrame();
      rendering = true;
      let report;
      try {
        report = active.runFrame(input);
      } finally {
        rendering = false;
      }
      const output = completedOutput();
      const saveWrites = saveMemory.takeWrites();
      const saveCommit = saveMemory.takeCommit();
      return {
        ...report,
        drawCommands,
        audioCommands,
        saveWrites,
        ...(saveCommit === undefined ? {} : { saveCommit }),
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
        if (snapshot.revision === 6)
          saveMemory.restoreDevice(snapshot.save, snapshot.pendingSaveWrites);
        else saveMemory.restore(snapshot.save, snapshot.pendingSaveWrites);
        if (snapshot.revision >= 2) {
          graphics.restore(snapshot.graphics);
          synthesizer.restore(snapshot.audio);
        }
        if (snapshot.revision >= 4) bus.restore(snapshot.memory);
        else if (snapshot.revision >= 2) {
          const visual = new VisualAssetStore(assets.visual, assets.display).memoryRegions()[0];
          if (visual === undefined) throw new TypeError('missing visual image');
          if (snapshot.revision === 3 && isMemorySnapshot(snapshot.memory)) {
            bus.restore({
              revision: 1,
              regions: [
                ...snapshot.memory.regions,
                { address: MEMORY.visual, bytes: visual.bytes },
              ].sort((a, b) => a.address - b.address),
            });
          } else {
            ram.fill(0);
            visualStore.memoryRegions()[0]?.bytes.set(visual.bytes);
          }
        }
      } catch (error) {
        requireMachine().restore(before.machine);
        saveMemory.restoreDevice(before.save, before.pendingSaveWrites);
        graphics.restore(before.graphics);
        synthesizer.restore(before.audio);
        bus.restore(before.memory);
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
      revision: 6,
      machine: requireMachine().snapshot(),
      save: saveMemory.deviceSnapshot(),
      graphics: graphics.snapshot(),
      audio: synthesizer.snapshot(),
      pendingSaveWrites: saveMemory.pendingWrites(),
      memory: bus.snapshot(),
    };
  }

  function completedOutput(): ConsoleFrame['output'] {
    if (frameOutput === undefined)
      throw new RuntimeFault('PX9102', 'frame completed without device output', {
        start: 0,
        end: 0,
      });
    return frameOutput;
  }

  function handleConsoleCall(
    name: string,
    arguments_: readonly unknown[],
    sourceSpan: SourceSpan,
    context: ExecutionContext,
  ): unknown {
    if (name === 'visual_id' || name === 'audio_id') {
      if (arguments_.length !== 1 || typeof arguments_[0] !== 'string')
        throw new RuntimeFault('PX9009', `${name} expects one Text name`, sourceSpan);
      requireMachine().work(1 + arguments_[0].length, sourceSpan);
      return (name === 'visual_id' ? visualStore : audioStore).id(arguments_[0]);
    }
    if (MEMORY_CALLS.has(name)) {
      if (arguments_.length !== MEMORY_CALLS.get(name))
        throw new RuntimeFault('PX9009', `${name} received the wrong argument count`, sourceSpan);
      const values = arguments_.map((value) => readInteger(value, sourceSpan));
      const address = values[0] ?? 0;
      const second = values[1] ?? 0;
      const third = values[2] ?? 0;
      const raster = context.phase === 'raster';
      switch (name) {
        case 'mem_read':
          return bus.read(address, 1, sourceSpan);
        case 'mem_read16':
          return bus.read(address, 2, sourceSpan);
        case 'mem_write': {
          bus.write(address, second, 1, sourceSpan, raster);
          return;
        }
        case 'mem_write16': {
          bus.write(address, second, 2, sourceSpan, raster);
          return;
        }
        case 'mem_copy': {
          bus.copy(address, second, third, sourceSpan, raster);
          return;
        }
        case 'mem_fill': {
          bus.fill(address, second, third, sourceSpan, raster);
          return;
        }
      }
    }
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
    if (name === 'save_commit') {
      if (arguments_.length !== 0)
        throw new RuntimeFault('PX9009', 'save_commit expects no arguments', sourceSpan);
      requireMachine().work(HARDWARE.saveCapacityBytes, sourceSpan);
      try {
        saveMemory.commit();
      } catch (error) {
        throw new RuntimeFault(
          'PX9012',
          error instanceof Error ? error.message : 'invalid save commit',
          sourceSpan,
        );
      }
      return;
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
    throw new RuntimeFault('PX9009', 'console arguments must be safe integers', sourceSpan);
  }
  return value;
}

function readWorkerSnapshot(value: unknown): {
  revision: 1 | 2 | 3 | 4 | 5 | 6;
  machine: unknown;
  save: SaveValues | SaveSnapshot;
  graphics: unknown;
  audio: unknown;
  pendingSaveWrites: readonly SaveWrite[];
  memory: unknown;
} {
  if (
    !isRecord(value) ||
    (value.revision === 6 ? !isConsoleRuntimeSnapshot(value) : !isLegacyWorkerSnapshot(value))
  ) {
    throw new RuntimeFault('PX9103', 'invalid worker snapshot', { start: 0, end: 0 });
  }
  return {
    revision: value.revision as 1 | 2 | 3 | 4 | 5 | 6,
    machine: value.machine,
    save: value.save as SaveValues | SaveSnapshot,
    graphics: value.graphics,
    audio: value.audio,
    pendingSaveWrites:
      value.revision === 1 ? [] : (value.pendingSaveWrites as readonly SaveWrite[]),
    memory: value.memory,
  };
}

function isLegacyWorkerSnapshot(value: Record<string, unknown>): boolean {
  if (
    !isMachineSnapshot(value.machine) ||
    value.machine.revision !== (value.revision === 5 ? 2 : 1) ||
    !isSaveValues(value.save)
  )
    return false;
  if (value.revision === 1) return Object.keys(value).length === 3;
  if (value.revision !== 2 && value.revision !== 3 && value.revision !== 4 && value.revision !== 5)
    return false;
  return (
    Object.keys(value).length === (value.revision === 2 ? 6 : 7) &&
    isGraphicsSnapshot(value.graphics) &&
    isSynthSnapshot(value.audio) &&
    isPendingSaveWrites(value.pendingSaveWrites, value.save) &&
    (value.revision === 2 ||
      (isMemorySnapshot(value.memory) && graphicsMatchesMemory(value.graphics, value.memory)))
  );
}

function graphicsMatchesMemory(graphics: GraphicsSnapshot, memory: MemorySnapshot): boolean {
  return [
    [MEMORY.front, graphics.front],
    [MEMORY.display, graphics.resolved],
  ].every(([address, pixels]) => {
    if (!(pixels instanceof Uint8Array)) return false;
    const bytes = memory.regions.find((region) => region.address === address)?.bytes;
    return (
      bytes !== undefined &&
      bytes.length === pixels.length &&
      bytes.every((value, index) => value === pixels[index])
    );
  });
}

const MEMORY_CALLS = new Map([
  ['mem_read', 1],
  ['mem_read16', 1],
  ['mem_write', 2],
  ['mem_write16', 2],
  ['mem_copy', 3],
  ['mem_fill', 3],
]);
