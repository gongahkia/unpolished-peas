import { isInputFrame, type InputFrame } from './input';
import { isRuntimeAssetSource, type RuntimeAssetSource } from './asset-codec';
import { isAudioFrame, isSynthSnapshot, type AudioFrame, type SynthSnapshot } from './audio';
import { HARDWARE } from './hardware';
import { isMapQueryCatalog, type MapQueryAsset } from './map-query';
import { isSaveValues, type SaveValues, type SaveWrite } from './save';

export interface SourceSpan {
  readonly start: number;
  readonly end: number;
}

export interface DebugStackFrame {
  readonly name: string;
  readonly sourceSpan: SourceSpan;
}

export interface DebugTraceEvent {
  readonly id: number;
  readonly sourceSpan: SourceSpan;
  readonly locals: unknown;
  readonly callStack: readonly DebugStackFrame[];
}

export interface DebugFrame {
  readonly trace: readonly DebugTraceEvent[];
  readonly truncated: boolean;
  readonly inspection: {
    readonly state: unknown;
    readonly tasks: unknown;
    readonly callStack: unknown;
  };
}

export interface SandboxConfiguration {
  readonly seed: number;
  readonly workUnitsPerFrame: number;
  readonly updateRate: 30 | 60;
  readonly maps?: readonly MapQueryAsset[];
  readonly save?: SaveValues;
  readonly debug?: boolean;
  readonly assets?: RuntimeAssetSource;
}

export interface ConsoleOutput {
  readonly indexedPixels: Uint8Array;
  readonly audio: AudioFrame;
  readonly audioState: SynthSnapshot;
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
      readonly output: ConsoleOutput;
      readonly debug?: DebugFrame;
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
          'output',
          ...(value.debug === undefined ? [] : ['debug']),
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
        value.saveWrites.every(isSaveWrite) &&
        isConsoleOutput(value.output) &&
        (value.debug === undefined || isDebugFrame(value.debug))
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

export function isSandboxConfiguration(value: unknown): value is SandboxConfiguration {
  return (
    isRecord(value) &&
    hasExactKeys(value, [
      'seed',
      'workUnitsPerFrame',
      'updateRate',
      ...(value.maps === undefined ? [] : ['maps']),
      ...(value.save === undefined ? [] : ['save']),
      ...(value.debug === undefined ? [] : ['debug']),
      ...(value.assets === undefined ? [] : ['assets']),
    ]) &&
    Number.isSafeInteger(value.seed) &&
    isNonNegativeInteger(value.workUnitsPerFrame) &&
    value.workUnitsPerFrame > 0 &&
    value.workUnitsPerFrame <= HARDWARE.workUnitsPerFrame &&
    (value.updateRate === 30 || value.updateRate === 60) &&
    (value.maps === undefined || isMapQueryCatalog(value.maps)) &&
    (value.save === undefined || isSaveValues(value.save)) &&
    (value.debug === undefined || typeof value.debug === 'boolean') &&
    (value.assets === undefined || isRuntimeAssetSource(value.assets))
  );
}

export function isConsoleOutput(value: unknown): value is ConsoleOutput {
  return (
    isRecord(value) &&
    hasExactKeys(value, ['indexedPixels', 'audio', 'audioState']) &&
    value.indexedPixels instanceof Uint8Array &&
    value.indexedPixels.length === HARDWARE.width * HARDWARE.height &&
    value.indexedPixels.every((color) => color < HARDWARE.paletteSize) &&
    isAudioFrame(value.audio) &&
    isSynthSnapshot(value.audioState)
  );
}

function isDebugFrame(value: unknown): value is DebugFrame {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, ['trace', 'truncated', 'inspection']) ||
    !Array.isArray(value.trace) ||
    typeof value.truncated !== 'boolean' ||
    !isRecord(value.inspection) ||
    !hasExactKeys(value.inspection, ['state', 'tasks', 'callStack'])
  ) {
    return false;
  }
  return value.trace.every(
    (event) =>
      isRecord(event) &&
      hasExactKeys(event, ['id', 'sourceSpan', 'locals', 'callStack']) &&
      isNonNegativeInteger(event.id) &&
      isSourceSpan(event.sourceSpan) &&
      Array.isArray(event.callStack) &&
      event.callStack.every(
        (frame) =>
          isRecord(frame) &&
          hasExactKeys(frame, ['name', 'sourceSpan']) &&
          typeof frame.name === 'string' &&
          isSourceSpan(frame.sourceSpan),
      ),
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
