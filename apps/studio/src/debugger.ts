import {
  BrowserInput,
  consoleReplayObservable,
  decodeRuntimeAssets,
  evaluateWatch,
  HARDWARE,
  isConsoleRuntimeSnapshot,
  ReplayJournal,
  SandboxSession,
  WebAudioSink,
  WebGlIndexedRenderer,
  type DebugTraceEvent,
  type GraphicsSnapshot,
  type InputFrame,
  type MemoryRegionDescriptor,
  type SaveImage,
  type SynthSnapshot,
  type RuntimeAssetSource,
} from '@px240c/runtime';

import { BrowserCompiler, type CompilationResult } from './compiler';

export interface DebugProject {
  readonly id: string;
  readonly title: string;
  readonly manifest: string;
  readonly files: Readonly<Record<string, Uint8Array>>;
}

export interface ActiveDebugger {
  readonly stop: () => void;
}

interface DebuggerSnapshot {
  readonly revision: 1;
  readonly worker: unknown;
  readonly graphics: GraphicsSnapshot;
  readonly audio: SynthSnapshot;
}

type FrameResponse = Awaited<ReturnType<SandboxSession['frame']>>;
type DebugTab = 'SOURCE' | 'STATE' | 'TASKS' | 'PROFILE' | 'MEMORY' | 'AUDIO';

const SNAPSHOT_INTERVAL = 30;
const WORK_LIMIT = HARDWARE.workUnitsPerFrame;
const decoder = new TextDecoder();

export async function openDebugger(
  root: HTMLElement,
  project: DebugProject,
  compiler: BrowserCompiler,
  save: SaveImage,
  back: () => void,
  manual: () => void,
): Promise<ActiveDebugger> {
  const controller = await DebuggerController.create(root, project, compiler, save, back, manual);
  try {
    await controller.start();
  } catch (error) {
    controller.stop();
    throw error;
  }
  return {
    stop: () => {
      controller.stop();
    },
  };
}

class DebuggerController {
  private readonly journal = new ReplayJournal(3_600);
  private readonly breakpoints = new Map<number, string>();
  private readonly watches: string[] = [];
  private readonly profile = new Map<string, { start: number; end: number; units: number }>();
  private readonly source: string;
  private readonly sourceLines: readonly string[];
  private readonly symbolNames: ReadonlyMap<number, string>;
  private readonly sandbox: SandboxSession;
  private readonly input: BrowserInput;
  private lastPixels: Uint8Array = new Uint8Array(HARDWARE.width * HARDWARE.height);
  private readonly renderer: WebGlIndexedRenderer;
  private lastAudio: SynthSnapshot | undefined;
  private readonly packedBytes: number;
  private readonly visualBytes: number;
  private readonly visualAssets: readonly { readonly name: string; readonly kind: string }[];
  private readonly displayRasterRows: number;
  private audioSink: WebAudioSink | undefined;
  private lastFrame: FrameResponse | undefined;
  private selectedTrace = -1;
  private currentFrame = 0;
  private tab: DebugTab = 'SOURCE';
  private memoryAddress = 0;
  private memoryLength = 64;
  private memoryRadix: 10 | 16 = 16;
  private memoryBytes = new Uint8Array();
  private previousMemoryBytes = new Uint8Array();
  private lastMemoryAddress = -1;
  private memoryRegions: readonly MemoryRegionDescriptor[] = [];
  private readonly memoryWatchpoints = new Map<number, number>();
  private running = false;
  private busy = false;
  private stopped = false;
  private message = 'PAUSED AT FRAME 0';

  public static async create(
    root: HTMLElement,
    project: DebugProject,
    compiler: BrowserCompiler,
    save: SaveImage,
    back: () => void,
    manual: () => void,
  ): Promise<DebuggerController> {
    const compilation = await compiler.compileProject(project.manifest, project.files, true);
    const diagnostic = compilation.analysis.diagnostics[0];
    const generated = compilation.generated;
    if (diagnostic !== undefined || generated === undefined) {
      throw new Error(
        diagnostic === undefined
          ? 'debug compiler produced no program'
          : `${diagnostic.code} ${diagnostic.message}`,
      );
    }
    const manifest = await compiler.parseManifest(project.manifest);
    const assets = decodeRuntimeAssets(manifest.assets, project.files, manifest.display);
    const rom = await compiler.packProject(project.manifest, project.files);
    const source = debugSource(compilation, project);
    return new DebuggerController(
      root,
      project,
      save,
      back,
      manual,
      compilation,
      generated.javascript,
      manifest.update_rate,
      assets,
      { declarations: manifest.assets, files: project.files, displayPath: manifest.display },
      rom,
      source,
    );
  }

  private constructor(
    private readonly root: HTMLElement,
    private readonly project: DebugProject,
    save: SaveImage,
    private readonly back: () => void,
    private readonly manual: () => void,
    compilation: CompilationResult,
    javascript: string,
    updateRate: 30 | 60,
    assets: ReturnType<typeof decodeRuntimeAssets>,
    assetSource: RuntimeAssetSource,
    rom: Uint8Array,
    source: string,
  ) {
    this.source = source;
    this.sourceLines = source.split('\n');
    this.symbolNames = new Map(
      compilation.analysis.symbols.map((symbol) => [symbol.id, symbol.name]),
    );
    this.packedBytes = rom.byteLength;
    this.visualBytes = assets.visualBytes;
    this.visualAssets = assets.visual.map((asset) => ({ name: asset.name, kind: asset.kind }));
    this.displayRasterRows = assets.display?.raster.length ?? 0;
    this.renderShell();
    const canvas = requireElement(this.root, '.debug-screen') as HTMLCanvasElement;
    this.sandbox = new SandboxSession(
      new Worker(new URL('../../../packages/runtime/src/sandbox-worker.ts', import.meta.url), {
        type: 'module',
        name: `px240c-debug-${project.id}`,
      }),
      1_000,
    );
    this.input = new BrowserInput(canvas);
    this.renderer = new WebGlIndexedRenderer(canvas);
    this.initialization = this.sandbox.load(javascript, {
      seed: 0x240c1999,
      workUnitsPerFrame: WORK_LIMIT,
      updateRate,
      assets: assetSource,
      save,
      rom,
      debug: true,
    });
  }

  private readonly initialization: Promise<void>;

  public async start(): Promise<void> {
    await this.initialization;
    await this.refreshMemory(false);
    this.journal.recordSnapshot(0, await this.captureSnapshot());
    this.bindControls();
    this.setControlsEnabled(true);
    requireElement(this.root, '.debugger').setAttribute('aria-busy', 'false');
    this.renderer.render(this.lastPixels);
    this.render();
    (requireElement(this.root, '.debugger') as HTMLElement).focus();
  }

  public stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    this.running = false;
    globalThis.removeEventListener('keydown', this.handleGlobalKey, true);
    this.input.destroy();
    this.sandbox.dispose();
    this.renderer.destroy();
    if (this.audioSink !== undefined) void this.audioSink.close();
  }

  private renderShell(): void {
    this.root.innerHTML = `
      <section class="display debugger" data-view="debugger" aria-label="PXCL source debugger" aria-busy="true" tabindex="-1">
        <header class="system-bar"><span>DEBUG / ${escapeHtml(this.project.id)}</span><span>FRAME TRACE</span></header>
        <main class="debug-stage">
          <div class="debug-left">
            <canvas class="debug-screen" width="240" height="144" aria-label="Debug framebuffer"></canvas>
            <label class="timeline-label">TIMELINE <input class="debug-timeline" type="range" min="0" max="0" value="0"></label>
            <p class="debug-location">NO TRACE</p>
          </div>
          <div class="debug-right">
            <nav class="debug-tabs" aria-label="Debugger inspectors"></nav>
            <pre class="debug-output" tabindex="0"></pre>
          </div>
        </main>
        <div class="debug-actions">
          <button type="button" data-debug="run">RUN</button><button type="button" data-debug="frame">FRAME</button><button type="button" data-debug="in">IN</button><button type="button" data-debug="over">OVER</button><button type="button" data-debug="out">OUT</button><button type="button" data-debug="rewind">-1F</button><button type="button" data-debug="restart">RST</button><button type="button" data-debug="sound">SND</button>
        </div>
        <div class="debug-entry">
          <div class="source-debug-entry">
            <input class="break-line" type="number" min="1" max="${String(this.sourceLines.length)}" value="1" aria-label="Breakpoint line"><input class="break-condition" type="text" placeholder="CONDITION" aria-label="Breakpoint condition"><button type="button" data-debug="break">BRK</button>
            <input class="watch-expression" type="text" placeholder="WATCH" aria-label="Watch expression"><button type="button" data-debug="watch">ADD</button>
          </div>
          <div class="memory-debug-entry" hidden>
            <input class="memory-address" type="text" value="000000" aria-label="Memory address"><input class="memory-length" type="number" min="1" max="64" value="64" aria-label="Memory length"><select class="memory-radix" aria-label="Memory number format"><option value="16">HEX</option><option value="10">DEC</option></select><button type="button" data-debug="memory-read">GET</button><input class="memory-value" type="text" value="00" aria-label="Memory byte value"><button type="button" data-debug="memory-write">SET</button><button type="button" data-debug="memory-watch">WP</button><button type="button" data-debug="memory-manual">MAN</button>
          </div>
        </div>
        <p class="debug-status" role="status" aria-live="polite">INITIALIZING HARDWARE</p>
        <button class="debug-back" type="button" data-debug="back">ESC BACK</button>
      </section>
    `;
    this.setControlsEnabled(false);
  }

  private setControlsEnabled(enabled: boolean): void {
    this.root
      .querySelectorAll<HTMLButtonElement | HTMLInputElement>('button, input')
      .forEach((control) => {
        control.disabled = !enabled;
      });
  }

  private bindControls(): void {
    const tabs = requireElement(this.root, '.debug-tabs');
    for (const tab of ['SOURCE', 'STATE', 'TASKS', 'PROFILE', 'MEMORY', 'AUDIO'] as const) {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = tab.slice(0, 4);
      button.addEventListener('click', () => {
        this.tab = tab;
        this.render();
        if (tab === 'MEMORY') void this.refreshMemory(true);
      });
      tabs.append(button);
    }
    this.root.querySelectorAll<HTMLButtonElement>('[data-debug]').forEach((button) => {
      button.addEventListener('click', () => {
        void this.action(button.dataset.debug ?? '');
      });
    });
    const timeline = requireElement(this.root, '.debug-timeline') as HTMLInputElement;
    timeline.addEventListener('change', () => {
      void this.rewind(Number(timeline.value));
    });
    globalThis.addEventListener('keydown', this.handleGlobalKey, true);
  }

  private readonly handleGlobalKey = (event: KeyboardEvent): void => {
    if (event.key === 'Escape' && event.shiftKey) {
      event.preventDefault();
      this.stop();
      this.back();
    }
  };

  private async action(action: string): Promise<void> {
    if (this.busy || this.stopped) return;
    try {
      switch (action) {
        case 'run':
          this.running = !this.running;
          this.message = this.running ? 'RUNNING' : `PAUSED AT FRAME ${String(this.currentFrame)}`;
          this.render();
          if (this.running) this.schedule();
          break;
        case 'frame':
          await this.advance(false);
          break;
        case 'in':
          await this.stepTrace('in');
          break;
        case 'over':
          await this.stepTrace('over');
          break;
        case 'out':
          await this.stepTrace('out');
          break;
        case 'rewind':
          await this.rewind(Math.max(this.journal.oldestFrame, this.currentFrame - 1));
          break;
        case 'restart':
          await this.rewind(0);
          break;
        case 'break':
          this.toggleBreakpoint();
          break;
        case 'watch':
          this.addWatch();
          break;
        case 'sound':
          await this.enableSound();
          break;
        case 'memory-read':
          await this.refreshMemory(true);
          this.message = `MEMORY ${hexAddress(this.memoryAddress)} READ`;
          this.render();
          break;
        case 'memory-write':
          await this.editMemory();
          break;
        case 'memory-watch':
          await this.toggleMemoryWatchpoint();
          break;
        case 'memory-manual':
          this.stop();
          this.manual();
          break;
        case 'back':
          this.stop();
          this.back();
          break;
      }
    } catch (error: unknown) {
      this.running = false;
      this.message = errorMessage(error);
      this.render();
    }
  }

  private schedule(): void {
    requestAnimationFrame(() => {
      void this.tick();
    });
  }

  private async tick(): Promise<void> {
    if (!this.running || this.busy || this.stopped) return;
    await this.advance(false);
    this.schedule();
  }

  private async advance(selectFirstTrace: boolean): Promise<void> {
    this.busy = true;
    try {
      if (this.currentFrame < this.journal.cursor) this.journal.truncate(this.currentFrame);
      const input = this.input.poll();
      const response = await this.executeFrame(input, true);
      if (response.frame !== this.currentFrame) {
        throw new Error(
          `replay cursor expected frame ${String(this.currentFrame)}, received ${String(response.frame)}`,
        );
      }
      this.journal.recordFrame(response.frame, input, consoleReplayObservable(response));
      this.currentFrame = response.frame + 1;
      if (this.currentFrame % SNAPSHOT_INTERVAL === 0) {
        this.journal.recordSnapshot(this.currentFrame, await this.captureSnapshot());
      }
      this.selectedTrace = selectFirstTrace && (response.debug?.trace.length ?? 0) > 0 ? 0 : -1;
      this.collectProfile(response);
      const memoryHit = await this.changedMemoryWatchpoint();
      const breakpoint = this.hitBreakpoint(response);
      if (memoryHit !== undefined) {
        this.running = false;
        this.message = `WATCH ${hexAddress(memoryHit.address)} ${byteHex(memoryHit.before)}>${byteHex(memoryHit.after)}`;
      } else if (breakpoint !== undefined) {
        this.running = false;
        this.selectedTrace = breakpoint.trace;
        this.message = `BREAK LINE ${String(breakpoint.line)} / FRAME ${String(response.frame)}`;
      } else if (!this.running) {
        this.message = `PAUSED AT FRAME ${String(this.currentFrame)}`;
      }
      if (this.tab === 'MEMORY') await this.refreshMemory(true);
      this.render();
    } finally {
      this.busy = false;
    }
  }

  private async executeFrame(input: InputFrame, audible: boolean): Promise<FrameResponse> {
    const response = await this.sandbox.frame(input);
    if (response.debug === undefined) throw new Error('debug worker omitted trace data');
    this.lastPixels = response.output.indexedPixels;
    this.lastAudio = response.output.audioState;
    this.renderer.render(this.lastPixels);
    if (audible) this.audioSink?.enqueue(response.output.audio);
    this.lastFrame = response;
    return response;
  }

  private async captureSnapshot(): Promise<DebuggerSnapshot> {
    const worker = await this.sandbox.snapshot();
    if (!isConsoleRuntimeSnapshot(worker)) throw new TypeError('worker omitted device snapshot');
    const graphics = worker.graphics;
    const audio = worker.audio;
    this.lastPixels = graphics.resolved;
    this.lastAudio = audio;
    return {
      revision: 1,
      worker,
      graphics,
      audio,
    };
  }

  private async rewind(target: number): Promise<void> {
    this.running = false;
    this.busy = true;
    this.message = `REPLAYING TO ${String(target)}`;
    this.render();
    try {
      const result = await this.journal.replay(target, {
        restore: async (value) => {
          const snapshot = readDebuggerSnapshot(value);
          await this.sandbox.restore(snapshot.worker);
          this.lastPixels = snapshot.graphics.resolved;
          this.lastAudio = snapshot.audio;
          this.renderer.render(snapshot.graphics.resolved);
          this.lastFrame = undefined;
        },
        frame: async (input) => consoleReplayObservable(await this.executeFrame(input, false)),
      });
      this.currentFrame = result.frame;
      this.selectedTrace = -1;
      await this.refreshWatchpoints();
      this.message =
        result.divergence === undefined
          ? `REWOUND TO FRAME ${String(result.frame)}`
          : `DIVERGENCE F${String(result.divergence.frame)} ${result.divergence.expected}/${result.divergence.actual}`;
    } finally {
      this.busy = false;
      this.render();
    }
  }

  private async stepTrace(kind: 'in' | 'over' | 'out'): Promise<void> {
    const trace = this.lastFrame?.debug?.trace ?? [];
    if (trace.length === 0 || this.selectedTrace < 0) {
      await this.advance(true);
      return;
    }
    const current = trace[this.selectedTrace];
    if (current === undefined) return;
    const depth = current.callStack.length;
    const next = trace.findIndex((event, index) => {
      if (index <= this.selectedTrace) return false;
      if (kind === 'in') return true;
      if (kind === 'over') return event.callStack.length <= depth;
      return event.callStack.length < depth;
    });
    if (next >= 0) {
      this.selectedTrace = next;
      this.message = `TRACE ${String(next + 1)}/${String(trace.length)} / EXECUTION PAUSED`;
      this.render();
    } else {
      await this.advance(true);
    }
  }

  private hitBreakpoint(
    response: FrameResponse,
  ): { readonly line: number; readonly trace: number } | undefined {
    const trace = response.debug?.trace ?? [];
    for (let index = 0; index < trace.length; index += 1) {
      const event = trace[index];
      if (event === undefined) continue;
      const line = lineForOffset(this.source, event.sourceSpan.start);
      const condition = this.breakpoints.get(line);
      if (condition === undefined) continue;
      if (condition.length === 0 || evaluateBreakpoint(condition, this.environment(event))) {
        return { line, trace: index };
      }
    }
    return undefined;
  }

  private toggleBreakpoint(): void {
    const line = Number((requireElement(this.root, '.break-line') as HTMLInputElement).value);
    if (!Number.isSafeInteger(line) || line < 1 || line > this.sourceLines.length) {
      throw new RangeError('breakpoint line is outside the linked debug source');
    }
    const condition = (
      requireElement(this.root, '.break-condition') as HTMLInputElement
    ).value.trim();
    if (this.breakpoints.has(line) && condition.length === 0) {
      this.breakpoints.delete(line);
      this.message = `REMOVED BREAKPOINT ${String(line)}`;
    } else {
      if (condition.length > 0) evaluateWatch(condition, this.environment(this.selectedEvent()));
      this.breakpoints.set(line, condition);
      this.message = `BREAKPOINT ${String(line)}${condition.length > 0 ? ' IF ' + condition : ''}`;
    }
    this.tab = 'SOURCE';
    this.render();
  }

  private addWatch(): void {
    const input = requireElement(this.root, '.watch-expression') as HTMLInputElement;
    const expression = input.value.trim();
    if (expression.length === 0) return;
    evaluateWatch(expression, this.environment(this.selectedEvent()));
    if (!this.watches.includes(expression)) this.watches.push(expression);
    if (this.watches.length > 4) this.watches.shift();
    input.value = '';
    this.tab = 'STATE';
    this.message = `WATCHING ${expression}`;
    this.render();
  }

  private async enableSound(): Promise<void> {
    this.audioSink ??= new WebAudioSink();
    await this.audioSink.resume();
    const button = this.root.querySelector<HTMLButtonElement>('[data-debug="sound"]');
    if (button !== null) {
      button.textContent = 'ON';
      button.disabled = true;
    }
  }

  private async refreshMemory(updateAddress: boolean): Promise<void> {
    const addressInput = this.root.querySelector<HTMLInputElement>('.memory-address');
    const lengthInput = this.root.querySelector<HTMLInputElement>('.memory-length');
    const radixInput = this.root.querySelector<HTMLSelectElement>('.memory-radix');
    if (updateAddress && addressInput !== null && lengthInput !== null) {
      this.memoryAddress = parseDebuggerAddress(addressInput.value);
      this.memoryLength = parseDebuggerInteger(lengthInput.value, 'memory length', 1, 64);
      this.memoryLength = Math.min(this.memoryLength, 0x400000 - this.memoryAddress);
      this.memoryRadix = radixInput?.value === '10' ? 10 : 16;
    }
    const response = await this.sandbox.inspectMemory(this.memoryAddress, this.memoryLength);
    this.previousMemoryBytes =
      response.address === this.lastMemoryAddress &&
      this.memoryBytes.length === response.bytes.length
        ? this.memoryBytes
        : new Uint8Array();
    this.memoryBytes = new Uint8Array(response.bytes);
    this.lastMemoryAddress = response.address;
    this.memoryRegions = response.regions;
    if (addressInput !== null) addressInput.value = hexAddress(this.memoryAddress);
    if (lengthInput !== null) lengthInput.value = String(this.memoryLength);
    this.render();
  }

  private async editMemory(): Promise<void> {
    this.running = false;
    const address = parseDebuggerAddress(
      (requireElement(this.root, '.memory-address') as HTMLInputElement).value,
    );
    const radix =
      (requireElement(this.root, '.memory-radix') as HTMLSelectElement).value === '10' ? 10 : 16;
    const value = parseDebuggerInteger(
      (requireElement(this.root, '.memory-value') as HTMLInputElement).value,
      'memory byte',
      0,
      255,
      radix,
    );
    await this.sandbox.editMemory(address, Uint8Array.of(value));
    this.memoryAddress = address;
    await this.refreshMemory(false);
    this.message = `SET ${hexAddress(address)}=${byteHex(value)} / PAUSED`;
    this.render();
  }

  private async toggleMemoryWatchpoint(): Promise<void> {
    const address = parseDebuggerAddress(
      (requireElement(this.root, '.memory-address') as HTMLInputElement).value,
    );
    if (this.memoryWatchpoints.has(address)) {
      this.memoryWatchpoints.delete(address);
      this.message = `REMOVED WATCH ${hexAddress(address)}`;
    } else {
      if (this.memoryWatchpoints.size >= 8)
        throw new RangeError('at most eight memory watchpoints');
      const response = await this.sandbox.inspectMemory(address, 1);
      this.memoryWatchpoints.set(address, response.bytes[0] ?? 0);
      this.message = `WATCHING ${hexAddress(address)}`;
    }
    this.render();
  }

  private async changedMemoryWatchpoint(): Promise<
    { readonly address: number; readonly before: number; readonly after: number } | undefined
  > {
    for (const [address, before] of this.memoryWatchpoints) {
      const response = await this.sandbox.inspectMemory(address, 1);
      const after = response.bytes[0] ?? 0;
      this.memoryWatchpoints.set(address, after);
      if (after !== before) return { address, before, after };
    }
    return undefined;
  }

  private async refreshWatchpoints(): Promise<void> {
    for (const address of this.memoryWatchpoints.keys()) {
      const response = await this.sandbox.inspectMemory(address, 1);
      this.memoryWatchpoints.set(address, response.bytes[0] ?? 0);
    }
  }

  private collectProfile(response: FrameResponse): void {
    for (const attribution of response.attribution) {
      const key = `${String(attribution.sourceSpan.start)}:${String(attribution.sourceSpan.end)}`;
      const previous = this.profile.get(key);
      this.profile.set(key, {
        start: attribution.sourceSpan.start,
        end: attribution.sourceSpan.end,
        units: (previous?.units ?? 0) + attribution.units,
      });
    }
  }

  private selectedEvent(): DebugTraceEvent | undefined {
    return this.lastFrame?.debug?.trace[this.selectedTrace];
  }

  private environment(event: DebugTraceEvent | undefined): Readonly<Record<string, unknown>> {
    const state = this.lastFrame?.debug?.inspection.state;
    return {
      ...namedValues(state, this.symbolNames),
      ...namedValues(event?.locals, this.symbolNames),
    };
  }

  private render(): void {
    const status = this.root.querySelector<HTMLElement>('.debug-status');
    if (status === null) return;
    status.textContent = this.message;
    const run = this.root.querySelector<HTMLButtonElement>('[data-debug="run"]');
    if (run !== null) run.textContent = this.running ? 'PAUSE' : 'RUN';
    const timeline = requireElement(this.root, '.debug-timeline') as HTMLInputElement;
    timeline.min = String(this.journal.oldestFrame);
    timeline.max = String(this.journal.cursor);
    timeline.value = String(this.currentFrame);
    const event = this.selectedEvent();
    const location = requireElement(this.root, '.debug-location');
    location.textContent =
      event === undefined
        ? `F${String(this.currentFrame).padStart(4, '0')} / NO TRACE SELECTED`
        : `F${String(this.currentFrame - 1).padStart(4, '0')} L${String(lineForOffset(this.source, event.sourceSpan.start))} P${String(event.id)}`;
    const output = requireElement(this.root, '.debug-output');
    output.textContent = this.tabOutput(this.tab, event);
    this.root.querySelectorAll<HTMLButtonElement>('.debug-tabs button').forEach((button) => {
      button.classList.toggle('active', button.textContent === this.tab.slice(0, 4));
    });
    const memoryMode = this.tab === 'MEMORY';
    const sourceEntry = this.root.querySelector<HTMLElement>('.source-debug-entry');
    const memoryEntry = this.root.querySelector<HTMLElement>('.memory-debug-entry');
    if (sourceEntry !== null) sourceEntry.hidden = memoryMode;
    if (memoryEntry !== null) memoryEntry.hidden = !memoryMode;
  }

  private tabOutput(tab: DebugTab, event: DebugTraceEvent | undefined): string {
    switch (tab) {
      case 'SOURCE':
        return sourceOutput(
          this.sourceLines,
          event,
          this.breakpoints,
          this.lastFrame?.debug?.truncated ?? false,
        );
      case 'STATE': {
        const environment = this.environment(event);
        const values = Object.entries(environment).map(
          ([name, value]) => `${name} = ${shortValue(value)}`,
        );
        const watches = this.watches.map((watch) => {
          try {
            return `? ${watch} = ${shortValue(evaluateWatch(watch, environment))}`;
          } catch (error: unknown) {
            return `? ${watch} ! ${errorMessage(error)}`;
          }
        });
        return [...values, ...watches].join('\n') || 'NO STATE AT CURRENT TRACE';
      }
      case 'TASKS': {
        const tasks = this.lastFrame?.debug?.inspection.tasks;
        const stack = event?.callStack ?? [];
        return `CALL STACK\n${stack.map((frame) => frame.name).join('\n') || '(FRAME BOUNDARY)'}\n\nTASKS\n${namedTaskValue(tasks, this.symbolNames)}`;
      }
      case 'PROFILE':
        return (
          [...this.profile.values()]
            .sort((left, right) => right.units - left.units || left.start - right.start)
            .slice(0, 12)
            .map(
              (item) =>
                `L${String(lineForOffset(this.source, item.start)).padStart(3, '0')} ${String(item.units).padStart(7, ' ')} WU`,
            )
            .join('\n') || 'ADVANCE A FRAME TO PROFILE'
        );
      case 'MEMORY': {
        return memoryOutput(
          this.memoryAddress,
          this.memoryBytes,
          this.previousMemoryBytes,
          this.memoryRadix,
          this.memoryRegions,
          this.memoryWatchpoints,
          {
            packedBytes: this.packedBytes,
            visualBytes: this.visualBytes,
            rasterRows: this.displayRasterRows,
            visualAssets: this.visualAssets,
          },
        );
      }
      case 'AUDIO': {
        const snapshot = this.lastAudio;
        if (snapshot === undefined) return 'NO AUDIO SNAPSHOT';
        const voices = snapshot.voices
          .map(
            (voice, index) =>
              `${String(index)} ${voice.active ? voice.sound + ' N' + String(voice.note) : '--'}`,
          )
          .join('\n');
        const tracker = snapshot.tracker;
        return `FRAME ${String(snapshot.frame)}\nTRACK ${tracker === null ? '--' : `${tracker.music} ${String(tracker.orderIndex)}:${String(tracker.row)}`}\n\n${voices}`;
      }
    }
  }
}

function memoryOutput(
  address: number,
  bytes: Uint8Array,
  previous: Uint8Array,
  radix: 10 | 16,
  regions: readonly MemoryRegionDescriptor[],
  watchpoints: ReadonlyMap<number, number>,
  metrics: {
    readonly packedBytes: number;
    readonly visualBytes: number;
    readonly rasterRows: number;
    readonly visualAssets: readonly { readonly name: string; readonly kind: string }[];
  },
): string {
  const region = regions.find(
    (entry) => address >= entry.address && address < entry.address + entry.length,
  );
  const lines = Array.from({ length: Math.ceil(bytes.length / 8) }, (_, row) => {
    const start = row * 8;
    const cells = [...bytes.slice(start, start + 8)].map((byte, column) => {
      const changed = previous[start + column] !== undefined && previous[start + column] !== byte;
      const value = radix === 16 ? byteHex(byte) : String(byte).padStart(3, '0');
      return `${changed ? '*' : ' '}${value}`;
    });
    return `${hexAddress(address + start)} ${cells.join(' ')}`;
  });
  const watched = [...watchpoints.keys()].sort((left, right) => left - right);
  const labels = regions
    .filter(
      (entry) => entry.address < address + bytes.length && entry.address + entry.length > address,
    )
    .map(
      (entry) =>
        `${hexAddress(entry.address)} ${entry.writable ? 'RW' : 'R '} ${entry.name.toUpperCase()}`,
    );
  return `${region?.name.toUpperCase() ?? 'RESERVED'} ${region?.writable ? 'RW' : 'R'} / ${radix === 16 ? 'HEX' : 'DEC'}
${lines.join('\n') || 'NO BYTES'}

${labels.join('\n') || 'UNMAPPED / READS ZERO'}
WP ${watched.map(hexAddress).join(' ') || '(NONE)'}
CART ${String(metrics.packedBytes)}/${String(HARDWARE.cartridgeCapacityBytes)} VIS ${String(metrics.visualBytes)}/${String(HARDWARE.visualCapacityBytes)} R${String(metrics.rasterRows)} A${String(metrics.visualAssets.length)}`;
}

function parseDebuggerInteger(
  source: string,
  label: string,
  minimum: number,
  maximum: number,
  forcedRadix?: 10 | 16,
): number {
  const trimmed = source.trim();
  const radix = forcedRadix ?? (/^0x/iu.test(trimmed) || /[a-f]/iu.test(trimmed) ? 16 : 10);
  const digits = trimmed.replace(/^0x/iu, '');
  const value = Number.parseInt(digits, radix);
  if (
    !/^[0-9a-f]+$/iu.test(digits) ||
    !Number.isSafeInteger(value) ||
    value < minimum ||
    value > maximum
  )
    throw new RangeError(`${label} must be ${String(minimum)}-${String(maximum)}`);
  return value;
}

function parseDebuggerAddress(source: string): number {
  return parseDebuggerInteger(source, 'memory address', 0, 0x3fffff, 16);
}

function hexAddress(value: number): string {
  return value.toString(16).toUpperCase().padStart(6, '0');
}

function byteHex(value: number): string {
  return value.toString(16).toUpperCase().padStart(2, '0');
}

function debugSource(compilation: CompilationResult, project: DebugProject): string {
  const sourceMap: unknown = JSON.parse(compilation.generated?.source_map_json ?? '{}');
  if (
    typeof sourceMap === 'object' &&
    sourceMap !== null &&
    Array.isArray((sourceMap as { sourcesContent?: unknown }).sourcesContent) &&
    typeof (sourceMap as { sourcesContent: unknown[] }).sourcesContent[0] === 'string'
  ) {
    return (sourceMap as { sourcesContent: string[] }).sourcesContent[0] ?? '';
  }
  const entry = /^entry\s*=\s*"([A-Za-z0-9_./-]+)"\s*$/m.exec(project.manifest)?.[1];
  return entry === undefined || project.files[entry] === undefined
    ? ''
    : decoder.decode(project.files[entry]);
}

function sourceOutput(
  lines: readonly string[],
  event: DebugTraceEvent | undefined,
  breakpoints: ReadonlyMap<number, string>,
  truncated: boolean,
): string {
  const line = event === undefined ? 1 : lineForOffset(lines.join('\n'), event.sourceSpan.start);
  const start = Math.max(1, line - 3);
  const end = Math.min(lines.length, line + 4);
  const excerpt: string[] = [];
  for (let current = start; current <= end; current += 1) {
    excerpt.push(
      `${current === line ? '>' : ' '} ${breakpoints.has(current) ? '*' : ' '} ${String(current).padStart(3, '0')} ${lines[current - 1] ?? ''}`,
    );
  }
  const listed = [...breakpoints.entries()]
    .sort(([left], [right]) => left - right)
    .map(([number, condition]) => `L${String(number)}${condition ? ' IF ' + condition : ''}`);
  return `${truncated ? 'TRACE TRUNCATED AT 4096 EVENTS\n' : ''}${excerpt.join('\n')}\n\nBREAKPOINTS\n${listed.join('\n') || '(NONE)'}`;
}

function namedValues(
  value: unknown,
  names: ReadonlyMap<number, string>,
): Readonly<Record<string, unknown>> {
  if (!isRecord(value)) return {};
  return Object.fromEntries(
    Object.entries(value).map(([key, entry]) => {
      const id = /^s(\d+)$/u.exec(key)?.[1];
      const name = id === undefined ? key : (names.get(Number(id)) ?? key);
      return [name, entry];
    }),
  );
}

function namedTaskValue(value: unknown, names: ReadonlyMap<number, string>): string {
  if (!Array.isArray(value) || value.length === 0) return '(NONE)';
  return value
    .map((task, index) => {
      if (!isRecord(task)) return `${String(index)} ?`;
      const kind =
        typeof task.kind === 'number' ? (names.get(task.kind) ?? String(task.kind)) : '?';
      return `${debugScalar(task.id, index)} ${kind} PC${debugScalar(task.pc)} WAIT${debugScalar(task.wait)}\n  ${shortValue(namedValues(task.locals, names))}`;
    })
    .join('\n');
}

function evaluateBreakpoint(
  expression: string,
  environment: Readonly<Record<string, unknown>>,
): boolean {
  const value = evaluateWatch(expression, environment);
  if (typeof value !== 'boolean') throw new TypeError('breakpoint condition must produce Bool');
  return value;
}

function lineForOffset(source: string, offset: number): number {
  let line = 1;
  for (let index = 0; index < Math.min(offset, source.length); index += 1) {
    if (source[index] === '\n') line += 1;
  }
  return line;
}

function readDebuggerSnapshot(value: unknown): DebuggerSnapshot {
  if (
    !isRecord(value) ||
    value.revision !== 1 ||
    !('worker' in value) ||
    !('graphics' in value) ||
    !('audio' in value)
  ) {
    throw new TypeError('invalid debugger snapshot');
  }
  return value as unknown as DebuggerSnapshot;
}

function shortValue(value: unknown): string {
  if (value === undefined) return 'undefined';
  const text = JSON.stringify(value);
  return text.length > 160 ? `${text.slice(0, 157)}...` : text;
}

function debugScalar(value: unknown, fallback: string | number = '?'): string {
  return typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean'
    ? String(value)
    : String(fallback);
}

function requireElement(root: ParentNode, selector: string): Element {
  const element = root.querySelector(selector);
  if (element === null) throw new Error(`debugger is missing '${selector}'`);
  return element;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message.toUpperCase() : 'UNKNOWN DEBUGGER ERROR';
}

function escapeHtml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}
