import { isInputFrame, type InputFrame } from './input';
import { HARDWARE } from './hardware';
import { isMapQueryCatalog, type MapQueryAsset } from './map-query';
import { isSaveValues, type SaveValues, type SaveWrite } from './save';

export interface SourceSpan {
  readonly start: number;
  readonly end: number;
}

export interface SandboxConfiguration {
  readonly seed: number;
  readonly workUnitsPerFrame: number;
  readonly updateRate: 30 | 60;
  readonly maps?: readonly MapQueryAsset[];
  readonly save?: SaveValues;
}

export type HostRequest =
  | {
      readonly id: number;
      readonly type: 'load';
      readonly moduleUrl: string;
      readonly configuration: SandboxConfiguration;
    }
  | { readonly id: number; readonly type: 'frame'; readonly input: InputFrame }
  | { readonly id: number; readonly type: 'audit' }
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
      readonly saveWrites: readonly SaveWrite[];
    }
  | { readonly id: number; readonly type: 'snapshot'; readonly snapshot: unknown }
  | { readonly id: number; readonly type: 'restored' }
  | {
      readonly id: number;
      readonly type: 'audit';
      readonly exposedCapabilities: readonly string[];
      readonly mathRandomAvailable: boolean;
    }
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
  readonly rasterLine?: number;
}

export function isHostRequest(value: unknown): value is HostRequest {
  if (!isRecord(value) || !isNonNegativeInteger(value.id) || typeof value.type !== 'string') {
    return false;
  }
  switch (value.type) {
    case 'load':
      return (
        hasExactKeys(value, ['id', 'type', 'moduleUrl', 'configuration']) &&
        typeof value.moduleUrl === 'string' &&
        value.moduleUrl.startsWith('blob:') &&
        isSandboxConfiguration(value.configuration)
      );
    case 'frame':
      return hasExactKeys(value, ['id', 'type', 'input']) && isInputFrame(value.input);
    case 'snapshot':
    case 'audit':
      return hasExactKeys(value, ['id', 'type']);
    case 'restore':
      return hasExactKeys(value, ['id', 'type', 'snapshot']);
    default:
      return false;
  }
}

export function isWorkerResponse(value: unknown): value is WorkerResponse {
  if (!isRecord(value) || !isNonNegativeInteger(value.id) || typeof value.type !== 'string') {
    return false;
  }
  switch (value.type) {
    case 'loaded':
    case 'restored':
      return hasExactKeys(value, ['id', 'type']);
    case 'snapshot':
      return hasExactKeys(value, ['id', 'type', 'snapshot']);
    case 'frame':
      return (
        hasExactKeys(value, [
          'id',
          'type',
          'frame',
          'workUnits',
          'attribution',
          'drawCommands',
          'audioCommands',
          'saveWrites',
        ]) &&
        isNonNegativeInteger(value.frame) &&
        isNonNegativeInteger(value.workUnits) &&
        Array.isArray(value.attribution) &&
        value.attribution.every(isAttribution) &&
        Array.isArray(value.drawCommands) &&
        value.drawCommands.every(isConsoleCommand) &&
        Array.isArray(value.audioCommands) &&
        value.audioCommands.every(isConsoleCommand) &&
        Array.isArray(value.saveWrites) &&
        value.saveWrites.every(isSaveWrite)
      );
    case 'audit':
      return (
        hasExactKeys(value, ['id', 'type', 'exposedCapabilities', 'mathRandomAvailable']) &&
        Array.isArray(value.exposedCapabilities) &&
        value.exposedCapabilities.every((capability) => typeof capability === 'string') &&
        typeof value.mathRandomAvailable === 'boolean'
      );
    case 'error':
      return (
        hasExactKeys(
          value,
          value.sourceSpan === undefined
            ? ['id', 'type', 'code', 'message']
            : ['id', 'type', 'code', 'message', 'sourceSpan'],
        ) &&
        typeof value.code === 'string' &&
        typeof value.message === 'string' &&
        (value.sourceSpan === undefined || isSourceSpan(value.sourceSpan))
      );
    default:
      return false;
  }
}

function isSandboxConfiguration(value: unknown): value is SandboxConfiguration {
  return (
    isRecord(value) &&
    hasExactKeys(value, [
      'seed',
      'workUnitsPerFrame',
      'updateRate',
      ...(value.maps === undefined ? [] : ['maps']),
      ...(value.save === undefined ? [] : ['save']),
    ]) &&
    Number.isSafeInteger(value.seed) &&
    isNonNegativeInteger(value.workUnitsPerFrame) &&
    value.workUnitsPerFrame > 0 &&
    (value.updateRate === 30 || value.updateRate === 60) &&
    (value.maps === undefined || isMapQueryCatalog(value.maps)) &&
    (value.save === undefined || isSaveValues(value.save))
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

function isSourceSpan(value: unknown): value is SourceSpan {
  return (
    isRecord(value) &&
    hasExactKeys(value, ['start', 'end']) &&
    isNonNegativeInteger(value.start) &&
    isNonNegativeInteger(value.end) &&
    value.start <= value.end
  );
}

function isAttribution(value: unknown): boolean {
  return (
    isRecord(value) &&
    hasExactKeys(value, ['sourceSpan', 'units']) &&
    isSourceSpan(value.sourceSpan) &&
    isNonNegativeInteger(value.units)
  );
}

function isConsoleCommand(value: unknown): value is ConsoleCommand {
  return (
    isRecord(value) &&
    hasExactKeys(
      value,
      value.rasterLine === undefined
        ? ['name', 'arguments', 'sourceSpan']
        : ['name', 'arguments', 'sourceSpan', 'rasterLine'],
    ) &&
    typeof value.name === 'string' &&
    Array.isArray(value.arguments) &&
    isSourceSpan(value.sourceSpan) &&
    (value.rasterLine === undefined ||
      (isNonNegativeInteger(value.rasterLine) && value.rasterLine < HARDWARE.height))
  );
}

function isSaveWrite(value: unknown): value is SaveWrite {
  return (
    isRecord(value) &&
    hasExactKeys(value, ['key', 'value']) &&
    typeof value.key === 'string' &&
    isSaveValues({ [value.key]: value.value })
  );
}

function hasExactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  return actual.length === expected.length && expected.every((key) => actual.includes(key));
}
