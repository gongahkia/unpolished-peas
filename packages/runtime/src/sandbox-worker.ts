import { DENIED_WORKER_CAPABILITIES, lockDownWorkerGlobals } from './capabilities';
import { RuntimeFault } from './errors';
import { DeterministicMachine, type CartridgeFactory, type ExecutionContext } from './machine';
import { HARDWARE } from './hardware';
import {
  isHostRequest,
  type ConsoleCommand,
  type HostRequest,
  type SourceSpan,
  type WorkerResponse,
} from './protocol';

interface WorkerPort {
  onmessage: ((event: MessageEvent<unknown>) => void) | null;
  postMessage(message: unknown): void;
}

const workerPort = globalThis as unknown as WorkerPort;
const send = workerPort.postMessage.bind(workerPort);
let machine: DeterministicMachine | undefined;
let drawCommands: ConsoleCommand[] = [];
let audioCommands: ConsoleCommand[] = [];

lockDownWorkerGlobals(globalThis);

workerPort.onmessage = (event: MessageEvent<unknown>): void => {
  if (!isHostRequest(event.data)) {
    send({
      id: requestId(event.data),
      type: 'error',
      code: 'PX9100',
      message: 'invalid sandbox protocol message',
    } satisfies WorkerResponse);
    return;
  }
  const request = event.data;
  void handleRequest(request).catch((error: unknown) => {
    const response = errorResponse(request.id, error);
    send(response);
  });
};

async function handleRequest(request: HostRequest): Promise<void> {
  switch (request.type) {
    case 'load': {
      const loaded: unknown = await import(/* @vite-ignore */ request.moduleUrl);
      const factory = readFactory(loaded);
      machine = new DeterministicMachine(factory, request.configuration, {
        call: handleConsoleCall,
      });
      machine.boot();
      send({ id: request.id, type: 'loaded' } satisfies WorkerResponse);
      break;
    }
    case 'frame': {
      const active = requireMachine();
      drawCommands = [];
      audioCommands = [];
      const report = active.runFrame(request.input);
      send({
        id: request.id,
        type: 'frame',
        frame: report.frame,
        workUnits: report.workUnits,
        attribution: report.attribution,
        drawCommands,
        audioCommands,
      } satisfies WorkerResponse);
      break;
    }
    case 'audit': {
      const globals = globalThis as Record<string, unknown>;
      const math = globals.Math;
      send({
        id: request.id,
        type: 'audit',
        exposedCapabilities: DENIED_WORKER_CAPABILITIES.filter(
          (capability) => globals[capability] !== undefined,
        ),
        mathRandomAvailable:
          typeof math === 'object' &&
          math !== null &&
          typeof (math as Record<string, unknown>).random === 'function',
      } satisfies WorkerResponse);
      break;
    }
    case 'snapshot':
      send({
        id: request.id,
        type: 'snapshot',
        snapshot: requireMachine().snapshot(),
      } satisfies WorkerResponse);
      break;
    case 'restore':
      requireMachine().restore(request.snapshot);
      send({ id: request.id, type: 'restored' } satisfies WorkerResponse);
      break;
  }
}

function handleConsoleCall(
  name: string,
  arguments_: readonly unknown[],
  sourceSpan: SourceSpan,
  context: ExecutionContext,
): unknown {
  requireMachine().work(consoleWorkCost(name, arguments_), sourceSpan);
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
  if (name === 'save_get_int') {
    return arguments_[1] ?? 0;
  }
  if (name === 'save_set_int') {
    return undefined;
  }
  throw new RuntimeFault('PX9004', `console API call '${name}' is unavailable`, sourceSpan);
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

function consoleWorkCost(name: string, arguments_: readonly unknown[]): number {
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
      return Math.max(1, String(arguments_[0] ?? '').length * 6);
    case 'sfx':
    case 'music':
    case 'music_stop':
      return 8;
    default:
      return 1;
  }
}

function readFactory(module: unknown): CartridgeFactory {
  if (!isRecord(module) || typeof module.default !== 'function') {
    throw new RuntimeFault('PX9101', 'compiled module does not export a cartridge factory', {
      start: 0,
      end: 0,
    });
  }
  return module.default as CartridgeFactory;
}

function requireMachine(): DeterministicMachine {
  if (machine === undefined) {
    throw new RuntimeFault('PX9102', 'no cartridge is loaded', { start: 0, end: 0 });
  }
  return machine;
}

function errorResponse(id: number, error: unknown): WorkerResponse {
  if (error instanceof RuntimeFault) {
    return {
      id,
      type: 'error',
      code: error.code,
      message: error.message,
      sourceSpan: error.sourceSpan,
    };
  }
  return {
    id,
    type: 'error',
    code: 'PX9199',
    message: error instanceof Error ? error.message : 'unknown sandbox failure',
  };
}

function requestId(value: unknown): number {
  return isRecord(value) && typeof value.id === 'number' && Number.isSafeInteger(value.id)
    ? value.id
    : 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
