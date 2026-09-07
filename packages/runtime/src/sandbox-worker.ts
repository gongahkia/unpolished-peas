import { DENIED_WORKER_CAPABILITIES, lockDownWorkerGlobals } from './capabilities';
import { RuntimeFault } from './errors';
import { DeterministicMachine, type CartridgeFactory } from './machine';
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
): unknown {
  const command = { name, arguments: structuredClone(arguments_), sourceSpan };
  if (DRAW_CALLS.has(name)) {
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
  'sprite',
  'map',
  'pal',
  'raster_scroll',
  'print',
]);

const AUDIO_CALLS = new Set(['sfx', 'music']);

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
