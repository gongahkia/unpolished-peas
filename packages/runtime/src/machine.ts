import { WorkBudget, type WorkAttribution } from './budget';
import { RuntimeFault } from './errors';
import { orderedDither } from './graphics';
import { emptyInputFrame, isButton, isInputFrame, type InputFrame } from './input';
import type { SandboxConfiguration, SourceSpan } from './protocol';
import { DeterministicRng } from './rng';

export interface CartridgeSnapshot {
  readonly state: unknown;
  readonly tasks: unknown;
  readonly nextTaskId: number;
}

export interface CartridgeInspection {
  readonly state: unknown;
  readonly tasks: unknown;
  readonly callStack: unknown;
}

export interface GeneratedCartridge {
  start(): void;
  update(): void;
  draw(): void;
  raster(line: number): void;
  snapshot(): CartridgeSnapshot;
  restore(snapshot: CartridgeSnapshot): void;
  inspect(): CartridgeInspection;
}

export interface CartridgeApi {
  work(units: number, sourceSpan: SourceSpan): void;
  call(name: string, arguments_: readonly unknown[], sourceSpan: SourceSpan): unknown;
  fault(code: string, message: string, sourceSpan: SourceSpan): never;
  probe?(id: number, sourceSpan: SourceSpan, locals: unknown): void;
  enter?(name: string, sourceSpan: SourceSpan): void;
  leave?(): void;
}

export type CartridgeFactory = (api: CartridgeApi) => GeneratedCartridge;

export type ExecutionPhase = 'start' | 'update' | 'draw' | 'raster';

export interface ExecutionContext {
  readonly frame: number;
  readonly phase: ExecutionPhase;
  readonly rasterLine?: number;
}

export interface RuntimeHooks {
  readonly call?: (
    name: string,
    arguments_: readonly unknown[],
    sourceSpan: SourceSpan,
    context: ExecutionContext,
  ) => unknown;
  readonly probe?: (id: number, sourceSpan: SourceSpan, locals: unknown) => void;
  readonly enter?: (name: string, sourceSpan: SourceSpan) => void;
  readonly leave?: () => void;
}

export interface FrameReport {
  readonly frame: number;
  readonly workUnits: number;
  readonly attribution: readonly WorkAttribution[];
}

export interface MachineSnapshot {
  readonly revision: 1;
  readonly frame: number;
  readonly rngState: number;
  readonly cartridge: CartridgeSnapshot;
  readonly input: InputFrame;
  readonly previousInput: InputFrame;
}

/** Deterministic callback scheduler and the only API surface visible to generated cartridge code. */
export class DeterministicMachine implements CartridgeApi {
  private readonly budget: WorkBudget;
  private readonly rng: DeterministicRng;
  private readonly updateRate: 30 | 60;
  private readonly cartridge: GeneratedCartridge;
  private readonly hooks: RuntimeHooks;
  private currentFrame = 0;
  private booted = false;
  private input: InputFrame = emptyInputFrame();
  private previousInput: InputFrame = emptyInputFrame();
  private phase: ExecutionPhase = 'start';
  private rasterLine: number | undefined;

  public constructor(
    factory: CartridgeFactory,
    configuration: SandboxConfiguration,
    hooks: RuntimeHooks = {},
  ) {
    this.budget = new WorkBudget(configuration.workUnitsPerFrame);
    this.rng = new DeterministicRng(configuration.seed);
    this.updateRate = configuration.updateRate;
    this.hooks = hooks;
    this.cartridge = factory(this);
  }

  public get frame(): number {
    return this.currentFrame;
  }

  public get cartridgeTimeSeconds(): number {
    return this.currentFrame / 60;
  }

  public boot(): void {
    if (this.booted) {
      return;
    }
    this.budget.beginFrame();
    this.phase = 'start';
    this.rasterLine = undefined;
    this.cartridge.start();
    this.booted = true;
  }

  public runFrame(input: InputFrame): FrameReport {
    if (!this.booted) {
      this.boot();
    }
    this.previousInput = this.input;
    this.input = structuredClone(input);
    this.budget.beginFrame();
    if (this.updateRate === 60 || this.currentFrame % 2 === 0) {
      this.phase = 'update';
      this.cartridge.update();
    }
    this.phase = 'draw';
    this.cartridge.draw();
    for (let line = 0; line < 144; line += 1) {
      this.phase = 'raster';
      this.rasterLine = line;
      this.cartridge.raster(line);
    }
    this.rasterLine = undefined;
    const report: FrameReport = {
      frame: this.currentFrame,
      workUnits: this.budget.used,
      attribution: this.budget.attribution(),
    };
    this.currentFrame += 1;
    return report;
  }

  public snapshot(): MachineSnapshot {
    return structuredClone({
      revision: 1,
      frame: this.currentFrame,
      rngState: this.rng.state,
      cartridge: this.cartridge.snapshot(),
      input: this.input,
      previousInput: this.previousInput,
    });
  }

  public restore(value: unknown): void {
    if (!isMachineSnapshot(value)) {
      throw new TypeError('invalid PX-240C machine snapshot');
    }
    const snapshot = value;
    this.currentFrame = snapshot.frame;
    this.rng.restore(snapshot.rngState);
    this.input = structuredClone(snapshot.input);
    this.previousInput = structuredClone(snapshot.previousInput);
    this.cartridge.restore(structuredClone(snapshot.cartridge));
  }

  public inspect(): CartridgeInspection {
    return this.cartridge.inspect();
  }

  public work(units: number, sourceSpan: SourceSpan): void {
    this.budget.charge(units, sourceSpan);
  }

  public call(name: string, arguments_: readonly unknown[], sourceSpan: SourceSpan): unknown {
    switch (name) {
      case 'rng_num':
        expectArguments(name, arguments_, 0, sourceSpan);
        return this.rng.nextNum();
      case 'rng_int': {
        expectArguments(name, arguments_, 2, sourceSpan);
        const minimum = expectInteger(arguments_[0], sourceSpan);
        const maximum = expectInteger(arguments_[1], sourceSpan);
        try {
          return this.rng.nextInt(minimum, maximum);
        } catch (error: unknown) {
          return this.fault(
            'PX9007',
            error instanceof Error ? error.message : 'invalid RNG bounds',
            sourceSpan,
          );
        }
      }
      case 'Vec2':
        expectArguments(name, arguments_, 2, sourceSpan);
        return {
          x: expectNumber(arguments_[0], sourceSpan),
          y: expectNumber(arguments_[1], sourceSpan),
        };
      case 'Rect':
        expectArguments(name, arguments_, 4, sourceSpan);
        return {
          x: expectNumber(arguments_[0], sourceSpan),
          y: expectNumber(arguments_[1], sourceSpan),
          w: expectNumber(arguments_[2], sourceSpan),
          h: expectNumber(arguments_[3], sourceSpan),
        };
      case 'dither': {
        expectArguments(name, arguments_, 5, sourceSpan);
        return orderedDither(
          expectInteger(arguments_[0], sourceSpan),
          expectInteger(arguments_[1], sourceSpan),
          expectInteger(arguments_[2], sourceSpan),
          expectInteger(arguments_[3], sourceSpan),
          expectInteger(arguments_[4], sourceSpan),
        );
      }
      case 'btn':
      case 'btnp': {
        expectArguments(name, arguments_, 2, sourceSpan);
        const port = expectInteger(arguments_[0], sourceSpan);
        const button = arguments_[1];
        if (port < 0 || port >= 4 || !isButton(button)) {
          return this.fault('PX9008', 'invalid controller port or button', sourceSpan);
        }
        const pressed = this.input.controllers[port]?.buttons[button] ?? false;
        if (name === 'btn') {
          return pressed;
        }
        return pressed && !(this.previousInput.controllers[port]?.buttons[button] ?? false);
      }
      default: {
        const context: ExecutionContext = {
          frame: this.currentFrame,
          phase: this.phase,
          ...(this.rasterLine === undefined ? {} : { rasterLine: this.rasterLine }),
        };
        const result = this.hooks.call?.(name, arguments_, sourceSpan, context);
        if (this.hooks.call === undefined) {
          return this.fault('PX9004', `console API call '${name}' is unavailable`, sourceSpan);
        }
        return result;
      }
    }
  }

  public fault(code: string, message: string, sourceSpan: SourceSpan): never {
    throw new RuntimeFault(code, message, sourceSpan);
  }

  public probe(id: number, sourceSpan: SourceSpan, locals: unknown): void {
    this.hooks.probe?.(id, sourceSpan, locals);
  }

  public enter(name: string, sourceSpan: SourceSpan): void {
    this.hooks.enter?.(name, sourceSpan);
  }

  public leave(): void {
    this.hooks.leave?.();
  }
}

function isMachineSnapshot(value: unknown): value is MachineSnapshot {
  if (typeof value !== 'object' || value === null) {
    return false;
  }
  const candidate = value as Record<string, unknown>;
  return (
    candidate.revision === 1 &&
    Number.isSafeInteger(candidate.frame) &&
    typeof candidate.frame === 'number' &&
    candidate.frame >= 0 &&
    Number.isSafeInteger(candidate.rngState) &&
    isInputFrame(candidate.input) &&
    isInputFrame(candidate.previousInput) &&
    typeof candidate.cartridge === 'object' &&
    candidate.cartridge !== null
  );
}

function expectArguments(
  name: string,
  arguments_: readonly unknown[],
  count: number,
  sourceSpan: SourceSpan,
): void {
  if (arguments_.length !== count) {
    throw new RuntimeFault(
      'PX9009',
      `${name} expected ${String(count)} arguments, received ${String(arguments_.length)}`,
      sourceSpan,
    );
  }
}

function expectNumber(value: unknown, sourceSpan: SourceSpan): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new RuntimeFault('PX9009', 'expected a finite number', sourceSpan);
  }
  return value;
}

function expectInteger(value: unknown, sourceSpan: SourceSpan): number {
  const number = expectNumber(value, sourceSpan);
  if (!Number.isSafeInteger(number)) {
    throw new RuntimeFault('PX9009', 'expected a safe integer', sourceSpan);
  }
  return number;
}
