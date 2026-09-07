import { isInputFrame, type InputFrame } from './input';

export interface SourceSpan {
  readonly start: number;
  readonly end: number;
}

export interface SandboxConfiguration {
  readonly seed: number;
  readonly workUnitsPerFrame: number;
  readonly updateRate: 30 | 60;
}

export type HostRequest =
  | {
      readonly id: number;
      readonly type: 'load';
      readonly moduleUrl: string;
      readonly configuration: SandboxConfiguration;
    }
  | { readonly id: number; readonly type: 'frame'; readonly input: InputFrame }
  | { readonly id: number; readonly type: 'snapshot' }
  | { readonly id: number; readonly type: 'restore'; readonly snapshot: unknown };

export type WorkerResponse =
  | { readonly id: number; readonly type: 'loaded' }
  | {
      readonly id: number;
      readonly type: 'frame';
      readonly frame: number;
      readonly workUnits: number;
      readonly attribution: readonly {
        readonly sourceSpan: SourceSpan;
        readonly units: number;
      }[];
      readonly drawCommands: readonly ConsoleCommand[];
      readonly audioCommands: readonly ConsoleCommand[];
    }
  | { readonly id: number; readonly type: 'snapshot'; readonly snapshot: unknown }
  | { readonly id: number; readonly type: 'restored' }
  | {
      readonly id: number;
      readonly type: 'error';
      readonly code: string;
      readonly message: string;
      readonly sourceSpan?: SourceSpan;
    };

export interface ConsoleCommand {
  readonly name: string;
  readonly arguments: readonly unknown[];
  readonly sourceSpan: SourceSpan;
}

export function isHostRequest(value: unknown): value is HostRequest {
  if (!isRecord(value) || !isNonNegativeInteger(value.id) || typeof value.type !== 'string') {
    return false;
  }
  switch (value.type) {
    case 'load':
      return (
        typeof value.moduleUrl === 'string' &&
        value.moduleUrl.startsWith('blob:') &&
        isSandboxConfiguration(value.configuration)
      );
    case 'frame':
      return isInputFrame(value.input);
    case 'snapshot':
      return true;
    case 'restore':
      return 'snapshot' in value;
    default:
      return false;
  }
}

export function isWorkerResponse(value: unknown): value is WorkerResponse {
  return (
    isRecord(value) &&
    isNonNegativeInteger(value.id) &&
    typeof value.type === 'string' &&
    ['loaded', 'frame', 'snapshot', 'restored', 'error'].includes(value.type)
  );
}

function isSandboxConfiguration(value: unknown): value is SandboxConfiguration {
  return (
    isRecord(value) &&
    Number.isSafeInteger(value.seed) &&
    isNonNegativeInteger(value.workUnitsPerFrame) &&
    value.workUnitsPerFrame > 0 &&
    (value.updateRate === 30 || value.updateRate === 60)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}
