import { RuntimeFault } from './errors';
import { DeterministicMachine, type CartridgeFactory, type ExecutionContext } from './machine';
import { HARDWARE } from './hardware';
import { MapQueryStore } from './map-query';
import { SaveMemory, type SaveValues } from './save';
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
  snapshot(): unknown;
  restore(snapshot: unknown): void;
}

/** One production dispatcher for restricted Workers and deterministic headless hosts. */
export function createConsoleRuntime(
  factory: CartridgeFactory,
  configuration: SandboxConfiguration,
): ConsoleRuntime {
  let machine: DeterministicMachine | undefined = undefined;
  let drawCommands: ConsoleCommand[] = [];
  let audioCommands: ConsoleCommand[] = [];
  const mapQueries = new MapQueryStore(configuration.maps ?? []);
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
      const report = active.runFrame(input);
      return {
        ...report,
        drawCommands,
        audioCommands,
        saveWrites: saveMemory.takeWrites(),
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
    snapshot() {
      return { revision: 1, machine: requireMachine().snapshot(), save: saveMemory.snapshot() };
    },
    restore(value) {
      const snapshot = readWorkerSnapshot(value);
      requireMachine().restore(snapshot.machine);
      saveMemory.restore(snapshot.save);
    },
  };

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
        return mapQueries.cell(handle.name, integers[0] ?? 0, integers[1] ?? 0, integers[2] ?? 0);
      }
      if (name === 'map_flag' && integers.length === 4) {
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
      return undefined;
    }
    if (AUDIO_CALLS.has(name)) {
      audioCommands.push(command);
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

function readWorkerSnapshot(value: unknown): { machine: unknown; save: SaveValues } {
  if (!isRecord(value) || value.revision !== 1 || !('machine' in value) || !('save' in value)) {
    throw new RuntimeFault('PX9103', 'invalid worker snapshot', { start: 0, end: 0 });
  }
  return { machine: value.machine, save: value.save as SaveValues };
}
