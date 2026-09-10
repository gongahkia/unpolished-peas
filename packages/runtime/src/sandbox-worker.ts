import { DENIED_WORKER_CAPABILITIES, lockDownWorkerGlobals } from './capabilities';
import { createConsoleRuntime, type ConsoleRuntime } from './console-runtime';
import { RuntimeFault } from './errors';
import type { CartridgeFactory } from './machine';
import { isHostRequest, type HostRequest, type WorkerResponse } from './protocol';

interface WorkerPort {
  onmessage: ((event: MessageEvent<unknown>) => void) | null;
  postMessage(message: unknown): void;
}

const workerPort = globalThis as unknown as WorkerPort;
const send = workerPort.postMessage.bind(workerPort);
let runtime: ConsoleRuntime | undefined;

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
      runtime = createConsoleRuntime(readFactory(loaded), request.configuration);
      send({ id: request.id, type: 'loaded' } satisfies WorkerResponse);
      break;
    }
    case 'frame':
      send({
        id: request.id,
        type: 'frame',
        ...requireRuntime().runFrame(request.input),
      } satisfies WorkerResponse);
      break;
    case 'debug-step': {
      const result = requireRuntime().stepDebug(request.input);
      send({
        id: request.id,
        type: 'debug-step',
        ...('frame' in result
          ? { frame: result.frame }
          : 'booted' in result
            ? { booted: true as const }
            : { event: result.event, inspection: result.inspection }),
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
        snapshot: requireRuntime().snapshot(),
      } satisfies WorkerResponse);
      break;
    case 'restore':
      requireRuntime().restore(request.snapshot);
      send({ id: request.id, type: 'restored' } satisfies WorkerResponse);
      break;
    case 'memory':
      send({
        id: request.id,
        type: 'memory',
        ...requireRuntime().inspectMemory(request.address, request.length),
      } satisfies WorkerResponse);
      break;
    case 'memory-edit':
      requireRuntime().editMemory(request.address, request.bytes);
      send({ id: request.id, type: 'memory-edited' } satisfies WorkerResponse);
      break;
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

function requireRuntime(): ConsoleRuntime {
  if (runtime === undefined) {
    throw new RuntimeFault('PX9102', 'no cartridge is loaded', { start: 0, end: 0 });
  }
  return runtime;
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
