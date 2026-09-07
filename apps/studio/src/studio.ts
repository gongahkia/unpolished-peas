import {
  BrowserInput,
  HARDWARE,
  IndexedDbStorage,
  IndexedGraphics,
  isSaveValues,
  SandboxSession,
  StudioRepository,
  WebGlIndexedRenderer,
  type SaveValues,
  type StoredProject,
} from '@px240c/runtime';

import { BrowserCompiler, type CompilerDiagnostic } from './compiler';

interface WorkingProject {
  readonly id: string;
  readonly title: string;
  readonly manifest: string;
  readonly revision: number;
  readonly files: Record<string, Uint8Array>;
}

interface ActivePlayer {
  readonly sandbox: SandboxSession;
  readonly input: BrowserInput;
  readonly stop: () => void;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const PROJECT_ID = /^[a-z0-9][a-z0-9.-]{2,63}$/;

/** Diegetic boot monitor, command shell, source editor, and cartridge player foundation. */
export class StudioApp {
  private readonly root: HTMLElement;
  private readonly repository: StudioRepository;
  private readonly compiler = new BrowserCompiler();
  private activeProject: WorkingProject | undefined;
  private readonly terminalLines: string[] = [];
  private readonly history: string[] = [];
  private historyCursor = 0;
  private player: ActivePlayer | undefined;

  public constructor(root: HTMLElement, databaseName = 'px240c-studio') {
    this.root = root;
    this.repository = new StudioRepository(new IndexedDbStorage(databaseName));
  }

  public async boot(): Promise<void> {
    this.stopPlayer();
    this.terminalLines.length = 0;
    this.appendLines([
      'PX-240C COLOR DEVELOPMENT UNIT',
      'SYSTEM ROM 1.0  (C) 1999',
      `${String(HARDWARE.visualCapacityBytes / 1024)}K VISUAL STORE / ${String(HARDWARE.audioVoices)}V SOUND`,
      'PXCL/1 READY',
      '',
      "TYPE 'HELP' FOR COMMANDS",
    ]);
    const projects = await this.repository.listProjects();
    if (projects.length > 0) {
      this.activeProject = fromStored(projects[0] as StoredProject);
      this.appendLines([
        `AUTOLOAD ${this.activeProject.id} R${String(this.activeProject.revision)}`,
      ]);
    }
    this.renderShell();
    document.documentElement.dataset.studioReady = 'true';
  }

  private renderShell(): void {
    this.root.innerHTML = `
      <section class="display shell" data-view="shell" aria-label="PX-240C monitor shell">
        <header class="system-bar"><span>PX-240C</span><span class="active-cart"></span></header>
        <div class="terminal" role="log" aria-live="polite" aria-relevant="additions text"></div>
        <form class="command-line">
          <label for="command">&gt;</label>
          <input id="command" name="command" autocomplete="off" autocapitalize="off" spellcheck="false" aria-label="PX-240C command" />
          <span class="cursor" aria-hidden="true">_</span>
        </form>
      </section>
    `;
    this.refreshTerminal();
    const cart = this.root.querySelector<HTMLElement>('.active-cart');
    if (cart !== null) {
      cart.textContent = this.activeProject?.id.toUpperCase() ?? 'NO CART';
    }
    const form = requireElement(this.root, '.command-line') as HTMLFormElement;
    const input = requireElement(this.root, '#command') as HTMLInputElement;
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const command = input.value.trim();
      input.value = '';
      if (command.length === 0) {
        return;
      }
      this.history.push(command);
      this.historyCursor = this.history.length;
      this.appendLines([`> ${command}`]);
      input.disabled = true;
      void this.execute(command).finally(() => {
        if (this.root.contains(input)) {
          input.disabled = false;
          input.focus();
        }
      });
    });
    input.addEventListener('keydown', (event) => {
      if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
        event.preventDefault();
        this.historyCursor = Math.max(
          0,
          Math.min(this.history.length, this.historyCursor + (event.key === 'ArrowUp' ? -1 : 1)),
        );
        input.value = this.history[this.historyCursor] ?? '';
      }
    });
    input.focus();
  }

  private async execute(commandLine: string): Promise<void> {
    const [command = '', ...arguments_] = splitCommand(commandLine);
    try {
      switch (command.toLowerCase()) {
        case 'dir':
          await this.directory();
          break;
        case 'new':
          await this.newProject(arguments_);
          break;
        case 'load':
          await this.loadProject(arguments_[0]);
          break;
        case 'save':
          await this.saveProject();
          break;
        case 'recover':
          await this.recoverProject(arguments_[0]);
          break;
        case 'edit':
          this.openEditor(arguments_[0]);
          return;
        case 'run':
          await this.runProject();
          return;
        case 'pack':
          await this.packProject();
          break;
        case 'info':
          await this.info();
          break;
        case 'help':
          this.appendLines([
            'DIR  NEW  LOAD  SAVE  RECOVER',
            'EDIT RUN PACK INFO HELP REBOOT',
            'NEW <ID> [TITLE] / LOAD <ID>',
          ]);
          break;
        case 'reboot':
          await this.boot();
          return;
        case 'export':
          this.appendLines(['EXPORT HTML: NOT IN THIS ROM REVISION']);
          break;
        case '':
          break;
        default:
          this.appendLines([`?UNKNOWN COMMAND: ${command.toUpperCase()}`]);
      }
    } catch (error: unknown) {
      this.appendLines([`!${errorMessage(error)}`]);
    }
    this.refreshTerminal();
  }

  private async directory(): Promise<void> {
    const projects = await this.repository.listProjects();
    if (projects.length === 0) {
      this.appendLines(['NO CARTRIDGES']);
      return;
    }
    this.appendLines(
      projects.map(
        (project) =>
          `${project.id === this.activeProject?.id ? '*' : ' '} ${project.id} R${String(project.revision)} ${project.title}`,
      ),
    );
  }

  private async newProject(arguments_: readonly string[]): Promise<void> {
    const [id, ...titleParts] = arguments_;
    if (id === undefined || !PROJECT_ID.test(id)) {
      throw new Error('NEW REQUIRES A 3-64 CHARACTER LOWERCASE ID');
    }
    if ((await this.repository.loadProject(id)) !== undefined) {
      throw new Error(`CARTRIDGE '${id}' ALREADY EXISTS`);
    }
    const title = (titleParts.join(' ') || id.replaceAll(/[.-]+/g, ' ')).toUpperCase().slice(0, 64);
    const manifest = `format = 1\nlanguage = "PXCL/1"\nid = "${id}"\ntitle = ${JSON.stringify(title)}\nauthor = "@gongahkia"\nversion = "0.1.0"\nentry = "src/main.pxl"\nupdate_rate = 60\n\n[assets]\n`;
    const project = await this.repository.saveProject({
      id,
      title,
      manifest,
      files: {
        'src/main.pxl': encoder.encode(
          '// Made by @gongahkia\n\nstate player_x: Int = 112\n\non update:\n  if btn(pad1, left):\n    player_x -= 1\n  if btn(pad1, right):\n    player_x += 1\n\non draw:\n  clear(1)\n  rect_fill(player_x, 64, 16, 16, 23)\n  print("PXCL/1", 98, 88, 7)\n',
        ),
      },
    });
    this.activeProject = fromStored(project);
    this.appendLines([`CREATED ${id}`, "EDIT 'src/main.pxl' OR RUN"]);
  }

  private async loadProject(id: string | undefined): Promise<void> {
    if (id === undefined) {
      throw new Error('LOAD REQUIRES A CARTRIDGE ID');
    }
    const project = await this.repository.loadProject(id);
    if (project === undefined) {
      throw new Error(`CARTRIDGE '${id}' NOT FOUND`);
    }
    this.activeProject = fromStored(project);
    this.appendLines([`LOADED ${id} R${String(project.revision)}`]);
  }

  private async saveProject(): Promise<void> {
    const project = this.requireProject();
    const stored = await this.repository.saveProject(project);
    this.activeProject = fromStored(stored);
    this.appendLines([`SAVED ${project.id} R${String(stored.revision)}`]);
  }

  private async recoverProject(revisionText: string | undefined): Promise<void> {
    const project = this.requireProject();
    const revisions = await this.repository.recoverySnapshots(project.id);
    if (revisions.length === 0) {
      this.appendLines(['NO RECOVERY REVISIONS']);
      return;
    }
    if (revisionText === undefined) {
      this.appendLines(
        revisions.map((revision) => `R${String(revision.revision)} ${revision.title}`),
      );
      return;
    }
    const requested = Number(revisionText.replace(/^r/i, ''));
    const recovered = revisions.find((revision) => revision.revision === requested);
    if (recovered === undefined) {
      throw new Error(`RECOVERY R${String(requested)} NOT FOUND`);
    }
    this.activeProject = fromStored(recovered);
    this.appendLines([`RECOVERED R${String(recovered.revision)} IN MEMORY`, 'USE SAVE TO COMMIT']);
  }

  private openEditor(path?: string): void {
    const project = this.requireProject();
    const selectedPath = path ?? manifestEntry(project.manifest);
    const bytes = project.files[selectedPath];
    if (bytes === undefined || !selectedPath.endsWith('.pxl')) {
      throw new Error(`SOURCE '${selectedPath}' NOT FOUND`);
    }
    this.root.innerHTML = `
      <section class="display editor" data-view="editor" aria-label="PXCL source editor">
        <header class="system-bar"><span>CODE</span><span class="editor-file"></span></header>
        <textarea class="source-input" spellcheck="false" aria-label="PXCL source"></textarea>
        <div class="diagnostic-strip" role="status" aria-live="polite">CHECKING...</div>
        <footer class="tool-bar">
          <button type="button" data-action="back">ESC BACK</button>
          <button type="button" data-action="format">F2 FORMAT</button>
          <button type="button" data-action="save">F3 SAVE</button>
          <button type="button" data-action="run">F5 RUN</button>
        </footer>
      </section>
    `;
    requireElement(this.root, '.editor-file').textContent = selectedPath;
    const textarea = requireElement(this.root, '.source-input') as HTMLTextAreaElement;
    textarea.value = decoder.decode(bytes);
    let analysisTimer: ReturnType<typeof setTimeout> | undefined;
    const updateWorkingCopy = (): void => {
      project.files[selectedPath] = encoder.encode(textarea.value);
      this.activeProject = project;
    };
    const analyze = (): void => {
      updateWorkingCopy();
      void this.showDiagnostics(selectedPath, textarea.value);
    };
    textarea.addEventListener('input', () => {
      if (analysisTimer !== undefined) {
        clearTimeout(analysisTimer);
      }
      analysisTimer = setTimeout(analyze, 120);
    });
    const editor = requireElement(this.root, '.editor');
    editor.addEventListener(
      'click',
      (event) => {
        const action = (event.target as HTMLElement).closest<HTMLElement>('[data-action]')?.dataset
          .action;
        if (action === undefined) {
          return;
        }
        updateWorkingCopy();
        if (action === 'back') {
          this.renderShell();
        } else if (action === 'format') {
          void this.compiler
            .format(selectedPath, textarea.value)
            .then((formatted) => {
              textarea.value = formatted;
              analyze();
            })
            .catch((error: unknown) => {
              this.setDiagnostic(errorMessage(error), true);
            });
        } else if (action === 'save') {
          void this.saveProject()
            .then(() => {
              this.setDiagnostic('SAVED', false);
            })
            .catch((error: unknown) => {
              this.setDiagnostic(errorMessage(error), true);
            });
        } else if (action === 'run') {
          void this.runProject().catch((error: unknown) => {
            this.setDiagnostic(errorMessage(error), true);
          });
        }
      },
      { once: false },
    );
    textarea.addEventListener('keydown', (event) => {
      const action =
        event.key === 'Escape'
          ? 'back'
          : event.key === 'F2'
            ? 'format'
            : event.key === 'F3'
              ? 'save'
              : event.key === 'F5'
                ? 'run'
                : undefined;
      if (action !== undefined) {
        event.preventDefault();
        (requireElement(this.root, `[data-action="${action}"]`) as HTMLButtonElement).click();
      }
    });
    void this.showDiagnostics(selectedPath, textarea.value);
    textarea.focus();
  }

  private async showDiagnostics(path: string, source: string): Promise<void> {
    try {
      const analysis = await this.compiler.analyze(path, source);
      const diagnostic = analysis.diagnostics[0];
      this.setDiagnostic(
        diagnostic === undefined ? 'OK / 0 ERRORS' : `${diagnostic.code} ${diagnostic.message}`,
        diagnostic !== undefined,
      );
    } catch (error: unknown) {
      this.setDiagnostic(errorMessage(error), true);
    }
  }

  private setDiagnostic(message: string, error: boolean): void {
    const strip = this.root.querySelector<HTMLElement>('.diagnostic-strip');
    if (strip !== null) {
      strip.textContent = message;
      strip.classList.toggle('error', error);
    }
  }

  private async runProject(): Promise<void> {
    const project = this.requireProject();
    const compilation = await this.compiler.compileProject(project.manifest, project.files, false);
    const diagnostic = compilation.analysis.diagnostics[0];
    if (diagnostic !== undefined || compilation.generated === undefined) {
      this.reportCompilerDiagnostic(diagnostic);
      return;
    }
    this.root.innerHTML = `
      <section class="display player" data-view="player" aria-label="Running PX-240C cartridge">
        <canvas class="player-screen" width="240" height="144" tabindex="0" aria-label="Cartridge display"></canvas>
        <button class="stop-player" type="button">SHIFT+ESC STOP</button>
        <p class="player-status" role="status"></p>
      </section>
    `;
    const canvas = requireElement(this.root, '.player-screen') as HTMLCanvasElement;
    const status = requireElement(this.root, '.player-status') as HTMLElement;
    const worker = new Worker(
      new URL('../../../packages/runtime/src/sandbox-worker.ts', import.meta.url),
      {
        type: 'module',
        name: `px240c-${project.id}`,
      },
    );
    const sandbox = new SandboxSession(worker, 1_000);
    const input = new BrowserInput(canvas);
    const graphics = new IndexedGraphics();
    const renderer = new WebGlIndexedRenderer(canvas);
    const saveAccess = this.repository.cartridgeSave(project.id);
    let saveValues = await readSaveValues(saveAccess);
    await sandbox.load(compilation.generated.javascript, {
      seed: 0x240c1999,
      workUnitsPerFrame: 50_000,
      updateRate: manifestUpdateRate(project.manifest),
      save: saveValues,
    });
    let stopped = false;
    const stopKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape' && event.shiftKey) {
        event.preventDefault();
        stop();
      }
    };
    const stop = (): void => {
      if (stopped) {
        return;
      }
      stopped = true;
      input.destroy();
      sandbox.dispose();
      globalThis.removeEventListener('keydown', stopKey, true);
      this.player = undefined;
      this.appendLines([`STOPPED ${project.id}`]);
      this.renderShell();
    };
    this.player = { sandbox, input, stop };
    (requireElement(this.root, '.stop-player') as HTMLButtonElement).addEventListener(
      'click',
      stop,
    );
    globalThis.addEventListener('keydown', stopKey, true);
    const frame = async (): Promise<void> => {
      if (stopped) {
        return;
      }
      try {
        const result = await sandbox.frame(input.poll());
        renderer.render(graphics.executeFrame(result.drawCommands).indexedPixels);
        if (result.saveWrites.length > 0) {
          saveValues = { ...saveValues };
          for (const write of result.saveWrites) {
            (saveValues as Record<string, number>)[write.key] = write.value;
          }
          await saveAccess.write(encoder.encode(JSON.stringify(saveValues)));
        }
        status.textContent = `F${String(result.frame).padStart(5, '0')} W${String(result.workUnits).padStart(5, '0')}`;
        requestAnimationFrame(() => void frame());
      } catch (error: unknown) {
        status.textContent = errorMessage(error);
        status.classList.add('error');
      }
    };
    canvas.focus();
    requestAnimationFrame(() => void frame());
  }

  private async packProject(): Promise<void> {
    const project = this.requireProject();
    const bytes = await this.compiler.packProject(project.manifest, project.files);
    const buffer = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(buffer).set(bytes);
    const url = URL.createObjectURL(new Blob([buffer], { type: 'application/x-px240c-cartridge' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = `${project.id}.pxc`;
    link.click();
    URL.revokeObjectURL(url);
    this.appendLines([`PACKED ${project.id}.pxc ${String(bytes.byteLength)} BYTES`]);
  }

  private async info(): Promise<void> {
    const identity = await this.compiler.identity();
    const project = this.activeProject;
    this.appendLines([
      `${identity.language} COMPILER ${identity.compiler}`,
      project === undefined
        ? 'NO CARTRIDGE LOADED'
        : `${project.id} / ${project.title} / R${String(project.revision)}`,
      '240X144 / 32 COLOR / 60HZ',
    ]);
  }

  private reportCompilerDiagnostic(diagnostic: CompilerDiagnostic | undefined): void {
    const message =
      diagnostic === undefined
        ? 'COMPILER PRODUCED NO PROGRAM'
        : `${diagnostic.code} ${diagnostic.message}`;
    if (this.root.querySelector('.editor') !== null) {
      this.setDiagnostic(message, true);
    } else {
      this.appendLines([`!${message}`]);
      this.refreshTerminal();
    }
  }

  private requireProject(): WorkingProject {
    if (this.activeProject === undefined) {
      throw new Error('NO CARTRIDGE LOADED');
    }
    return this.activeProject;
  }

  private stopPlayer(): void {
    this.player?.stop();
    this.player = undefined;
  }

  private appendLines(lines: readonly string[]): void {
    this.terminalLines.push(...lines);
    if (this.terminalLines.length > 80) {
      this.terminalLines.splice(0, this.terminalLines.length - 80);
    }
  }

  private refreshTerminal(): void {
    const terminal = this.root.querySelector<HTMLElement>('.terminal');
    if (terminal === null) {
      return;
    }
    terminal.replaceChildren(
      ...this.terminalLines.map((line) => {
        const paragraph = document.createElement('p');
        paragraph.textContent = line || '\u00a0';
        return paragraph;
      }),
    );
    terminal.scrollTop = terminal.scrollHeight;
  }
}

function fromStored(project: StoredProject): WorkingProject {
  return {
    id: project.id,
    title: project.title,
    manifest: project.manifest,
    revision: project.revision,
    files: Object.fromEntries(
      Object.entries(project.files).map(([path, bytes]) => [path, bytes.slice()]),
    ),
  };
}

function manifestEntry(manifest: string): string {
  return /^entry\s*=\s*"([A-Za-z0-9_./-]+)"\s*$/m.exec(manifest)?.[1] ?? 'src/main.pxl';
}

function manifestUpdateRate(manifest: string): 30 | 60 {
  return /^update_rate\s*=\s*30\s*$/m.test(manifest) ? 30 : 60;
}

async function readSaveValues(
  access: ReturnType<StudioRepository['cartridgeSave']>,
): Promise<SaveValues> {
  const bytes = await access.read();
  if (bytes.byteLength === 0) {
    return {};
  }
  try {
    const value: unknown = JSON.parse(decoder.decode(bytes));
    return isSaveValues(value) ? value : {};
  } catch {
    return {};
  }
}

function splitCommand(source: string): string[] {
  const result: string[] = [];
  for (const match of source.matchAll(/"([^"]*)"|'([^']*)'|(\S+)/g)) {
    result.push(match[1] ?? match[2] ?? match[3] ?? '');
  }
  return result;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message.toUpperCase() : 'UNKNOWN SYSTEM ERROR';
}

function requireElement(root: ParentNode, selector: string): Element {
  const element = root.querySelector(selector);
  if (element === null) {
    throw new Error(`studio element '${selector}' is missing`);
  }
  return element;
}
