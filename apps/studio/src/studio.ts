import {
  AudioAssetStore,
  BrowserInput,
  decodeRuntimeAssets,
  HARDWARE,
  IndexedDbStorage,
  IndexedGraphics,
  isSaveValues,
  SandboxSession,
  StudioRepository,
  Synthesizer,
  VisualAssetStore,
  WebAudioSink,
  WebGlIndexedRenderer,
  type SaveValues,
  type StoredProject,
} from '@px240c/runtime';

import { BrowserCompiler, type CompilerDiagnostic } from './compiler';
import { openDebugger, type ActiveDebugger } from './debugger';
import { openCreationTool, type CreationTool } from './tools';

interface WorkingProject {
  id: string;
  title: string;
  manifest: string;
  revision: number;
  files: Record<string, Uint8Array>;
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
  private activeDebugger: ActiveDebugger | undefined;

  public constructor(root: HTMLElement, databaseName = 'px240c-studio') {
    this.root = root;
    this.repository = new StudioRepository(new IndexedDbStorage(databaseName));
  }

  public async boot(): Promise<void> {
    this.stopPlayer();
    this.stopDebugger();
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
        case 'sprite':
        case 'map':
        case 'palette':
        case 'sfx':
        case 'music':
        case 'project':
          await this.openTool(command as CreationTool);
          return;
        case 'manual':
          this.openManual();
          return;
        case 'explore':
          await this.openExplorer();
          return;
        case 'run':
          await this.runProject();
          return;
        case 'debug':
          await this.debugProject();
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
            'EDIT RUN DEBUG PACK INFO HELP REBOOT',
            'PROJECT SPRITE MAP PALETTE SFX MUSIC',
            'MANUAL EXPLORE',
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
    Object.assign(project, fromStored(stored));
    this.activeProject = project;
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
        <pre class="source-highlight" aria-hidden="true"></pre>
        <textarea class="source-input" spellcheck="false" aria-label="PXCL source"></textarea>
        <div class="diagnostic-strip" role="status" aria-live="polite">CHECKING...</div>
        <footer class="tool-bar">
          <button type="button" data-action="back">ESC BACK</button>
          <button type="button" data-action="format">F2 FORMAT</button>
          <button type="button" data-action="save">F3 SAVE</button>
          <button type="button" data-action="symbol">F4 SYMBOL</button>
          <button type="button" data-action="run">F5 RUN</button>
          <button type="button" data-action="reload">F6 RELOAD</button>
        </footer>
      </section>
    `;
    requireElement(this.root, '.editor-file').textContent = selectedPath;
    const textarea = requireElement(this.root, '.source-input') as HTMLTextAreaElement;
    const highlight = requireElement(this.root, '.source-highlight') as HTMLElement;
    textarea.value = decoder.decode(bytes);
    renderHighlight(highlight, textarea.value);
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
      renderHighlight(highlight, textarea.value);
      if (analysisTimer !== undefined) {
        clearTimeout(analysisTimer);
      }
      analysisTimer = setTimeout(analyze, 120);
    });
    textarea.addEventListener('scroll', () => {
      highlight.scrollTop = textarea.scrollTop;
      highlight.scrollLeft = textarea.scrollLeft;
    });
    textarea.addEventListener('focus', () => {
      void this.repository.loadProject(project.id).then((stored) => {
        if (stored !== undefined && stored.revision > project.revision) {
          this.setDiagnostic(`R${String(stored.revision)} AVAILABLE / F6 RELOAD`, true);
        }
      });
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
        } else if (action === 'symbol') {
          gotoDefinition(textarea);
        } else if (action === 'reload') {
          void this.reloadEditorProject(project, selectedPath, textarea, highlight);
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
                : event.key === 'F4'
                  ? 'symbol'
                  : event.key === 'F6'
                    ? 'reload'
                    : undefined;
      if (event.ctrlKey && event.code === 'Space') {
        event.preventDefault();
        completeAtCursor(textarea);
        renderHighlight(highlight, textarea.value);
        analyze();
        return;
      }
      if (action !== undefined) {
        event.preventDefault();
        (requireElement(this.root, `[data-action="${action}"]`) as HTMLButtonElement).click();
      }
    });
    void this.showDiagnostics(selectedPath, textarea.value);
    textarea.focus();
  }

  private async reloadEditorProject(
    project: WorkingProject,
    path: string,
    textarea: HTMLTextAreaElement,
    highlight: HTMLElement,
  ): Promise<void> {
    const stored = await this.repository.loadProject(project.id);
    const source = stored?.files[path];
    if (stored === undefined || source === undefined) {
      this.setDiagnostic('NO EXTERNAL REVISION AVAILABLE', true);
      return;
    }
    Object.assign(project, fromStored(stored));
    this.activeProject = project;
    textarea.value = decoder.decode(source);
    renderHighlight(highlight, textarea.value);
    await this.showDiagnostics(path, textarea.value);
  }

  private async openTool(tool: CreationTool): Promise<void> {
    const project = this.requireProject();
    await openCreationTool(this.root, tool, project, {
      back: () => {
        this.renderShell();
      },
      save: async () => {
        await this.saveProject();
      },
      parseManifest: async () => this.compiler.parseManifest(project.manifest),
    });
  }

  private openManual(): void {
    const topics = manualTopics();
    this.root.innerHTML = `
      <section class="display manual" data-view="manual" aria-label="PX-240C manual browser">
        <header class="system-bar"><span>PXCL/1 MANUAL</span><span>ROM 1.0</span></header>
        <input class="manual-search" type="search" aria-label="Search manual" placeholder="SEARCH">
        <nav class="manual-topics" aria-label="Manual topics"></nav>
        <article class="manual-page" tabindex="0"></article>
        <footer class="tool-bar"><button type="button" data-back>ESC BACK</button></footer>
      </section>
    `;
    const search = requireElement(this.root, '.manual-search') as HTMLInputElement;
    const navigation = requireElement(this.root, '.manual-topics');
    const page = requireElement(this.root, '.manual-page');
    const show = (topic: (typeof topics)[number]): void => {
      page.replaceChildren();
      const heading = document.createElement('h1');
      heading.textContent = topic.title;
      const body = document.createElement('p');
      body.textContent = topic.body;
      page.append(heading, body);
    };
    const renderTopics = (): void => {
      const query = search.value.toLowerCase();
      const visible = topics.filter((topic) =>
        `${topic.title} ${topic.body}`.toLowerCase().includes(query),
      );
      navigation.replaceChildren(
        ...visible.map((topic) => {
          const button = document.createElement('button');
          button.type = 'button';
          button.textContent = topic.title;
          button.addEventListener('click', () => {
            show(topic);
          });
          return button;
        }),
      );
      const first = visible[0];
      if (first !== undefined) show(first);
    };
    search.addEventListener('input', renderTopics);
    const back = (): void => {
      this.renderShell();
    };
    this.root.querySelector('[data-back]')?.addEventListener('click', back);
    this.root.querySelector('[data-view="manual"]')?.addEventListener('keydown', (event) => {
      if ((event as KeyboardEvent).key === 'Escape') back();
    });
    renderTopics();
    search.focus();
  }

  private async openExplorer(): Promise<void> {
    const project = this.requireProject();
    const compilation = await this.compiler.compileProject(project.manifest, project.files, false);
    const panes: Readonly<Record<string, unknown>> = {
      TOKENS: compilation.analysis.tokens,
      AST: compilation.analysis.module,
      TYPED: compilation.analysis.symbols,
      IR: compilation.analysis.ir,
      JS: compilation.generated?.javascript ?? 'NO GENERATED PROGRAM',
      MAP: compilation.generated?.source_map_json ?? 'NO SOURCE MAP',
      DIAG: compilation.analysis.diagnostics,
      SIZE: {
        generatedBytes: compilation.generated?.generated_bytes ?? 0,
        probes: compilation.generated?.probe_count ?? 0,
        workModel: compilation.generated?.work_model ?? {},
      },
    };
    this.root.innerHTML = `
      <section class="display explorer" data-view="explorer" aria-label="PXCL compiler explorer">
        <header class="system-bar"><span>COMPILER EXPLORER</span><span>RELEASE</span></header>
        <nav class="explorer-tabs" aria-label="Compiler stages"></nav>
        <pre class="explorer-output" tabindex="0"></pre>
        <footer class="tool-bar"><button type="button" data-back>ESC BACK</button></footer>
      </section>
    `;
    const tabs = requireElement(this.root, '.explorer-tabs');
    const output = requireElement(this.root, '.explorer-output');
    const show = (name: string): void => {
      const value = panes[name];
      output.textContent = typeof value === 'string' ? value : JSON.stringify(value, undefined, 2);
    };
    for (const name of Object.keys(panes)) {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = name;
      button.addEventListener('click', () => {
        show(name);
      });
      tabs.append(button);
    }
    const back = (): void => {
      this.renderShell();
    };
    this.root.querySelector('[data-back]')?.addEventListener('click', back);
    this.root.querySelector('[data-view="explorer"]')?.addEventListener('keydown', (event) => {
      if ((event as KeyboardEvent).key === 'Escape') back();
    });
    show('TOKENS');
    (output as HTMLElement).focus();
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
    this.stopDebugger();
    const project = this.requireProject();
    const compilation = await this.compiler.compileProject(project.manifest, project.files, false);
    const diagnostic = compilation.analysis.diagnostics[0];
    if (diagnostic !== undefined || compilation.generated === undefined) {
      this.reportCompilerDiagnostic(diagnostic);
      return;
    }
    const parsedManifest = await this.compiler.parseManifest(project.manifest);
    const assets = decodeRuntimeAssets(
      parsedManifest.assets,
      project.files,
      parsedManifest.display,
    );
    this.root.innerHTML = `
      <section class="display player" data-view="player" aria-label="Running PX-240C cartridge">
        <canvas class="player-screen" width="240" height="144" tabindex="0" aria-label="Cartridge display"></canvas>
        <button class="stop-player" type="button">SHIFT+ESC STOP</button>
        <button class="enable-player-audio" type="button">SOUND</button>
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
    const graphics = new IndexedGraphics(new VisualAssetStore(assets.visual), assets.display);
    const renderer = new WebGlIndexedRenderer(canvas);
    const synthesizer = new Synthesizer(new AudioAssetStore(assets.audio));
    let audioSink: WebAudioSink | undefined;
    const saveAccess = this.repository.cartridgeSave(project.id);
    let saveValues = await readSaveValues(saveAccess);
    await sandbox.load(compilation.generated.javascript, {
      seed: 0x240c1999,
      workUnitsPerFrame: 50_000,
      updateRate: manifestUpdateRate(project.manifest),
      maps: assets.maps,
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
      if (audioSink !== undefined) {
        void audioSink.close();
      }
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
    (requireElement(this.root, '.enable-player-audio') as HTMLButtonElement).addEventListener(
      'click',
      (event) => {
        const button = event.currentTarget as HTMLButtonElement;
        audioSink = new WebAudioSink();
        void audioSink.resume().then(() => {
          button.textContent = 'SOUND ON';
          button.disabled = true;
        });
      },
      { once: true },
    );
    globalThis.addEventListener('keydown', stopKey, true);
    const frame = async (): Promise<void> => {
      if (stopped) {
        return;
      }
      try {
        const result = await sandbox.frame(input.poll());
        renderer.render(graphics.executeFrame(result.drawCommands).indexedPixels);
        const audioFrame = synthesizer.executeFrame(result.audioCommands);
        audioSink?.enqueue(audioFrame);
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

  private async debugProject(): Promise<void> {
    this.stopPlayer();
    const project = this.requireProject();
    const save = await readSaveValues(this.repository.cartridgeSave(project.id));
    try {
      this.activeDebugger = await openDebugger(this.root, project, this.compiler, save, () => {
        this.activeDebugger = undefined;
        this.appendLines([`DEBUG STOPPED ${project.id}`]);
        this.renderShell();
      });
    } catch (error: unknown) {
      this.renderShell();
      throw error;
    }
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

  private stopDebugger(): void {
    this.activeDebugger?.stop();
    this.activeDebugger = undefined;
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

const COMPLETIONS = [
  'state',
  'let',
  'var',
  'fn',
  'task',
  'on',
  'if',
  'else',
  'for',
  'while',
  'match',
  'return',
  'wait',
  'start',
  'clear',
  'pixel',
  'line',
  'rect',
  'rect_fill',
  'circle',
  'circle_fill',
  'triangle',
  'sprite',
  'animation',
  'map',
  'print',
  'btn',
  'btnp',
  'rng_int',
  'rng_num',
  'sfx',
  'music',
  'save_get_int',
  'save_set_int',
] as const;

function completeAtCursor(textarea: HTMLTextAreaElement): void {
  const cursor = textarea.selectionStart;
  const prefix = /[A-Za-z_][A-Za-z0-9_]*$/.exec(textarea.value.slice(0, cursor))?.[0] ?? '';
  const completion = COMPLETIONS.find((candidate) => candidate.startsWith(prefix));
  if (completion === undefined) {
    return;
  }
  const start = cursor - prefix.length;
  textarea.setRangeText(completion, start, cursor, 'end');
}

function gotoDefinition(textarea: HTMLTextAreaElement): void {
  const cursor = textarea.selectionStart;
  const left = textarea.value.slice(0, cursor).search(/[A-Za-z_][A-Za-z0-9_]*$/);
  const tail = /^[A-Za-z0-9_]*/.exec(textarea.value.slice(cursor))?.[0] ?? '';
  if (left < 0) return;
  const symbol = `${textarea.value.slice(0, cursor).slice(left)}${tail}`;
  const matcher = new RegExp(`^(?:state|const|fn|task|record|enum|let|var)\\s+${symbol}\\b`, 'm');
  const definition = matcher.exec(textarea.value);
  if (definition === null) return;
  const start = definition.index + definition[0].lastIndexOf(symbol);
  textarea.focus();
  textarea.setSelectionRange(start, start + symbol.length);
  const line = textarea.value.slice(0, start).split('\n').length - 1;
  textarea.scrollTop = Math.max(0, line * 7 - 28);
}

function renderHighlight(target: HTMLElement, source: string): void {
  const pattern =
    /\/\/.*$|"(?:\\.|[^"\\])*"|#[A-Za-z_][A-Za-z0-9_]*|\b(?:and|as|assert|break|case|const|continue|draw|elif|else|enum|false|fn|for|if|import|in|let|match|none|not|on|or|raster|record|return|start|state|task|true|update|var|wait|while)\b|\b\d+(?:\.\d+)?(?:f|s)?\b/gm;
  target.replaceChildren();
  let cursor = 0;
  for (const match of source.matchAll(pattern)) {
    const index = match.index;
    if (index > cursor) target.append(document.createTextNode(source.slice(cursor, index)));
    const token = document.createElement('span');
    const text = match[0];
    token.className = text.startsWith('//')
      ? 'syntax-comment'
      : text.startsWith('"')
        ? 'syntax-text'
        : text.startsWith('#')
          ? 'syntax-asset'
          : /^\d/.test(text)
            ? 'syntax-number'
            : 'syntax-keyword';
    token.textContent = text;
    target.append(token);
    cursor = index + text.length;
  }
  target.append(document.createTextNode(source.slice(cursor)));
}

function manualTopics(): readonly { readonly title: string; readonly body: string }[] {
  return [
    {
      title: 'START',
      body: 'Create with NEW id, open EDIT, then RUN. Save explicitly with F3 or SAVE. PACK downloads a deterministic source-inspectable cartridge.',
    },
    {
      title: 'PXCL',
      body: 'PXCL/1 is ASCII-only, statically typed, indentation-based, and deterministic. Mutable top-level values use state with an explicit type.',
    },
    {
      title: 'CALLBACKS',
      body: 'on start runs once. on update runs at 30 or 60 Hz. on draw renders every frame. on raster(line: Int) may change palette and scroll state.',
    },
    {
      title: 'TASKS',
      body: 'Declare task name(...): and launch it with start name(...). wait 2f suspends for frames; wait 0.5s converts to cartridge time.',
    },
    {
      title: 'DRAWING',
      body: 'Use clear, pixel, line, rect, circle, triangle, sprite, animation, map, print, camera, clip, pal, and raster_scroll. Colors are fixed indices 0-31.',
    },
    {
      title: 'INPUT',
      body: 'btn and btnp accept pad1 through pad4 and button values up/down/left/right/a/b/x/y/l/r/start_button/menu.',
    },
    {
      title: 'AUDIO',
      body: 'SFX are eight-voice oscillator patches. MUSIC opens the eight-channel pattern tracker. Imported PCM and arbitrary samples are unavailable.',
    },
    {
      title: 'LIMITS',
      body: '240x144, 32 colors, 128 KiB visual assets, 8 KiB save, 256 KiB packed cartridge, 4096 draw commands, 8 synth voices, 4 local ports.',
    },
  ];
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
