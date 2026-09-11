import {
  BrowserInput,
  HARDWARE,
  IndexedDbStorage,
  MASTER_PALETTE_RGBA,
  REPLAY_MAX_BYTES,
  SandboxSession,
  StudioRepository,
  WebAudioSink,
  WebGlIndexedRenderer,
  decodeCartridgePng,
  decodeCartridgeFragment,
  decodeReplayTrace,
  emptyInputFrame,
  encodeCartridgePng,
  encodeCartridgeFragment,
  encodeIndexedGif,
  encodeReplayTrace,
  encodeRgbaPng,
  encodeSingleFileZip,
  replayInputFrames,
  type DecodedPng,
  type InputFrame,
  type ReplayTrace,
  type StoredProject,
} from '@px240c/runtime';

import {
  BrowserCompiler,
  type CompilationResult,
  type CompilerDiagnostic,
  type ProjectManifest,
} from './compiler';
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
const BUNDLED_CARTRIDGES = [
  'cinder-circuit',
  'ashvault',
  'raster-rush',
  'px240c-service',
  'signal-4k',
  'pocket-relay',
  'hardware-gauntlet',
] as const;

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
  private readonly capturedFrames = new Map<string, Uint8Array>();

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
    const installed = await this.installBundledCartridges();
    if (installed > 0) {
      this.appendLines([`${String(installed)} BUILT-IN CARTRIDGES INSTALLED`]);
    }
    await this.importUrlFragment();
    const projects = await this.repository.listProjects();
    if (projects.length > 0 && this.activeProject === undefined) {
      this.activeProject = fromStored(projects[0] as StoredProject);
      this.appendLines([
        `AUTOLOAD ${this.activeProject.id} R${String(this.activeProject.revision)}`,
      ]);
    }
    this.renderShell();
    document.documentElement.dataset.studioReady = 'true';
  }

  private async installBundledCartridges(): Promise<number> {
    let installed = 0;
    for (const id of BUNDLED_CARTRIDGES) {
      if (await this.repository.isProjectRemoved(id)) continue;
      if ((await this.repository.loadProject(id)) !== undefined) {
        await this.repository.setShelfOrigin(id, 'bundled');
        continue;
      }
      const response = await fetch(new URL(`./cartridges/${id}.pxc`, document.baseURI));
      if (!response.ok) {
        throw new Error(`BUILT-IN CARTRIDGE ${id} COULD NOT BE READ`);
      }
      const unpacked = await this.compiler.unpackCartridge(
        new Uint8Array(await response.arrayBuffer()),
      );
      const manifest = await this.compiler.parseManifest(unpacked.manifest);
      await this.repository.saveProject({
        id: manifest.id,
        title: manifest.title,
        manifest: unpacked.manifest,
        files: Object.fromEntries(
          Object.entries(unpacked.files).map(([path, bytes]) => [path, Uint8Array.from(bytes)]),
        ),
      });
      await this.repository.setShelfOrigin(id, 'bundled');
      installed += 1;
    }
    return installed;
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
      if (this.activeProject !== undefined)
        void this.refreshActiveCartMeter(cart, this.activeProject);
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
        case 'shelf':
          await this.openShelf();
          return;
        case 'import':
          this.openImporter();
          return;
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
        case 'font':
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
        case 'cart':
          await this.exportCartridgePng();
          break;
        case 'share':
          await this.openShare();
          return;
        case 'info':
          await this.info();
          break;
        case 'inspect':
          await this.openInspector();
          return;
        case 'help':
          this.appendLines([
            'DIR SHELF NEW LOAD SAVE RECOVER IMPORT',
            'EDIT RUN DEBUG PACK CART EXPORT SHARE INSPECT INFO',
            'PROJECT SPRITE MAP PALETTE FONT SFX MUSIC',
            'MANUAL EXPLORE',
            'NEW <ID> [TITLE] / LOAD <ID>',
          ]);
          break;
        case 'reboot':
          await this.boot();
          return;
        case 'export':
          if (arguments_[0]?.toLowerCase() === 'zip') await this.exportZip();
          else await this.exportHtml();
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
    await this.repository.setShelfOrigin(id, 'created');
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

  private openImporter(): void {
    this.root.innerHTML = `
      <section class="display cartridge-import" data-view="import" aria-label="PX-240C cartridge import">
        <header class="system-bar"><span>CARTRIDGE IMPORT</span><span>PXC/1</span></header>
        <main>
          <p>SELECT A SOURCE-INSPECTABLE .PXC OR .PXC.PNG.</p>
          <p>AN EXISTING ID IS REPLACED WITH A RECOVERY SNAPSHOT.</p>
          <label class="import-pick">OPEN <input type="file" accept=".pxc,.pxc.png,application/x-px240c-cartridge,image/png"></label>
        </main>
        <p class="import-status" role="status" aria-live="polite">WAITING FOR CARTRIDGE</p>
        <footer class="tool-bar"><button type="button" data-back>ESC BACK</button></footer>
      </section>
    `;
    const section = requireElement(this.root, '[data-view="import"]');
    const input = requireElement(this.root, 'input[type="file"]') as HTMLInputElement;
    const back = (): void => {
      this.renderShell();
    };
    this.root.querySelector('[data-back]')?.addEventListener('click', back);
    section.addEventListener('keydown', (event) => {
      if ((event as KeyboardEvent).key === 'Escape') back();
    });
    input.addEventListener('change', () => {
      const file = input.files?.[0];
      if (file === undefined) return;
      void this.importCartridge(file).catch((error: unknown) => {
        const status = this.root.querySelector<HTMLElement>('.import-status');
        if (status !== null) {
          status.textContent = errorMessage(error);
          status.classList.add('error');
        }
      });
    });
    input.focus();
  }

  private async importCartridge(file: File): Promise<void> {
    if (file.size > 8 * 1024 * 1024)
      throw new RangeError('CARTRIDGE FILE EXCEEDS ITS FORMAT CAPACITY');
    const imported = new Uint8Array(await file.arrayBuffer());
    const isPng =
      imported.length >= 8 &&
      [137, 80, 78, 71, 13, 10, 26, 10].every((byte, index) => imported[index] === byte);
    if (!isPng && file.size > HARDWARE.cartridgeCapacityBytes)
      throw new RangeError('CARTRIDGE FILE EXCEEDS ITS FORMAT CAPACITY');
    const cartridge = isPng ? decodeCartridgePng(imported).cartridge : imported;
    const unpacked = await this.compiler.unpackCartridge(cartridge);
    const manifest = await this.compiler.parseManifest(unpacked.manifest);
    const project = await this.repository.saveProject({
      id: manifest.id,
      title: manifest.title,
      manifest: unpacked.manifest,
      files: Object.fromEntries(
        Object.entries(unpacked.files).map(([path, bytes]) => [path, Uint8Array.from(bytes)]),
      ),
    });
    this.activeProject = fromStored(project);
    await this.repository.setShelfOrigin(manifest.id, 'imported');
    this.appendLines([
      `IMPORTED ${manifest.id} R${String(project.revision)}`,
      `${String(Object.keys(project.files).length)} SOURCE/ASSET FILES`,
    ]);
    this.renderShell();
  }

  private async importUrlFragment(): Promise<void> {
    try {
      const cartridge = decodeCartridgeFragment(globalThis.location.hash);
      if (cartridge === undefined) return;
      const unpacked = await this.compiler.unpackCartridge(cartridge);
      const manifest = await this.compiler.parseManifest(unpacked.manifest);
      const project = await this.repository.saveProject({
        id: manifest.id,
        title: manifest.title,
        manifest: unpacked.manifest,
        files: Object.fromEntries(
          Object.entries(unpacked.files).map(([path, bytes]) => [path, Uint8Array.from(bytes)]),
        ),
      });
      this.activeProject = fromStored(project);
      await this.repository.setShelfOrigin(manifest.id, 'fragment');
      this.appendLines([`FRAGMENT IMPORT ${manifest.id} / ${String(cartridge.byteLength)} BYTES`]);
      history.replaceState(null, '', `${location.pathname}${location.search}`);
    } catch (error: unknown) {
      this.appendLines([`!FRAGMENT ${errorMessage(error)}`]);
    }
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
    let autosaveTimer: ReturnType<typeof setTimeout> | undefined;
    let saveQueue = Promise.resolve();
    let dirty = false;
    const updateWorkingCopy = (): void => {
      project.files[selectedPath] = encoder.encode(textarea.value);
      this.activeProject = project;
    };
    const persistWorkingCopy = (): Promise<void> => {
      updateWorkingCopy();
      if (!dirty) {
        return saveQueue.catch(() => undefined);
      }
      dirty = false;
      saveQueue = saveQueue
        .catch(() => undefined)
        .then(async () => {
          const stored = await this.repository.loadProject(project.id);
          if (stored !== undefined && stored.revision !== project.revision) {
            dirty = true;
            throw new Error(`R${String(stored.revision)} CHANGED EXTERNALLY / F6 RELOAD`);
          }
          const saved = await this.repository.saveProject(project);
          Object.assign(project, fromStored(saved));
          this.activeProject = project;
          if (this.root.contains(textarea)) {
            this.setDiagnostic(`AUTOSAVED R${String(saved.revision)}`, false);
          }
        });
      return saveQueue;
    };
    const scheduleAutosave = (): void => {
      if (autosaveTimer !== undefined) {
        clearTimeout(autosaveTimer);
      }
      autosaveTimer = setTimeout(() => {
        void persistWorkingCopy().catch((error: unknown) => {
          if (this.root.contains(textarea)) {
            this.setDiagnostic(errorMessage(error), true);
          }
        });
      }, 750);
    };
    const analyze = (): void => {
      updateWorkingCopy();
      void this.showDiagnostics(selectedPath, textarea.value);
    };
    textarea.addEventListener('input', () => {
      dirty = true;
      renderHighlight(highlight, textarea.value);
      if (analysisTimer !== undefined) {
        clearTimeout(analysisTimer);
      }
      analysisTimer = setTimeout(analyze, 120);
      scheduleAutosave();
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
          if (autosaveTimer !== undefined) {
            clearTimeout(autosaveTimer);
          }
          void persistWorkingCopy()
            .catch((error: unknown) => {
              this.appendLines([`!${errorMessage(error)}`]);
            })
            .finally(() => {
              this.renderShell();
            });
        } else if (action === 'format') {
          void this.compiler
            .format(selectedPath, textarea.value)
            .then((formatted) => {
              textarea.value = formatted;
              dirty = true;
              analyze();
              scheduleAutosave();
            })
            .catch((error: unknown) => {
              this.setDiagnostic(errorMessage(error), true);
            });
        } else if (action === 'save') {
          if (autosaveTimer !== undefined) {
            clearTimeout(autosaveTimer);
          }
          void persistWorkingCopy()
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
          if (autosaveTimer !== undefined) {
            clearTimeout(autosaveTimer);
          }
          void this.reloadEditorProject(project, selectedPath, textarea, highlight).then(() => {
            dirty = false;
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
                : event.key === 'F4'
                  ? 'symbol'
                  : event.key === 'F6'
                    ? 'reload'
                    : undefined;
      if (event.ctrlKey && event.code === 'Space') {
        event.preventDefault();
        completeAtCursor(textarea);
        dirty = true;
        renderHighlight(highlight, textarea.value);
        analyze();
        scheduleAutosave();
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
        const stored = await this.repository.loadProject(project.id);
        if (stored !== undefined && stored.revision !== project.revision)
          throw new Error(`R${String(stored.revision)} CHANGED EXTERNALLY / REOPEN TOOL`);
        await this.saveProject();
      },
      parseManifest: async () => this.compiler.parseManifest(project.manifest),
    });
  }

  private openManual(initialTitle = 'START'): void {
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
    const initial = topics.find((topic) => topic.title === initialTitle);
    if (initial !== undefined) show(initial);
    search.focus();
  }

  private async openExplorer(): Promise<void> {
    const project = this.requireProject();
    const [compilation, manifest, packed] = await Promise.all([
      this.compiler.compileProject(project.manifest, project.files, false),
      this.compiler.parseManifest(project.manifest),
      this.compiler.packProject(project.manifest, project.files),
    ]);
    const cartridge = await this.compiler.decodeCartridge(packed);
    const report = projectSizeReport(packed, cartridge.entries, manifest, compilation);
    const panes: Readonly<Record<string, unknown>> = {
      TOKENS: compilation.analysis.tokens,
      AST: compilation.analysis.module,
      TYPED: compilation.analysis.symbols,
      IR: compilation.analysis.ir,
      JS: compilation.generated?.javascript ?? 'NO GENERATED PROGRAM',
      MAP: compilation.generated?.source_map_json ?? 'NO SOURCE MAP',
      DIAG: compilation.analysis.diagnostics,
      SIZE: {
        ...report,
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

  private async runProject(replay?: ReplayTrace): Promise<void> {
    this.stopDebugger();
    const project = this.requireProject();
    const compilation = await this.compiler.compileProject(project.manifest, project.files, false);
    const diagnostic = compilation.analysis.diagnostics[0];
    if (diagnostic !== undefined || compilation.generated === undefined) {
      this.reportCompilerDiagnostic(diagnostic);
      return;
    }
    const parsedManifest = await this.compiler.parseManifest(project.manifest);
    const rom = await this.compiler.packProject(project.manifest, project.files);
    const saveAccess = this.repository.cartridgeSave(project.id);
    const save = await saveAccess.read();
    this.root.innerHTML = `
      <section class="display player" data-view="player"${replay === undefined ? '' : ' data-replay="true"'} aria-label="Running PX-240C cartridge">
        <canvas class="player-screen" width="240" height="144" tabindex="0" aria-label="Cartridge display"></canvas>
        <div class="capture-player"><label>SCALE <select class="capture-scale"><option>1</option><option>2</option><option>3</option><option>4</option></select></label><button class="capture-shot" type="button">PNG</button><button class="capture-gif" type="button">GIF 5S</button><button class="capture-replay" type="button">PXREC OUT</button><label class="file-button">PXREC IN<input class="replay-input" type="file" accept=".pxrec,application/json"></label></div>
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
    const renderer = new WebGlIndexedRenderer(canvas);
    let audioSink: WebAudioSink | undefined;
    const capturedFrames: Uint8Array[] = [];
    const capturedInputs: { frame: number; input: InputFrame }[] = [];
    const importedInputs = replay === undefined ? undefined : replayInputFrames(replay);
    let frameCursor = 0;
    try {
      await sandbox.load(compilation.generated.javascript, {
        seed: 0x240c1999,
        workUnitsPerFrame: HARDWARE.workUnitsPerFrame,
        updateRate: manifestUpdateRate(project.manifest),
        assets: {
          declarations: parsedManifest.assets,
          files: project.files,
          displayPath: parsedManifest.display,
        },
        save,
        rom,
      });
      await this.repository.markPlayed(project.id);
    } catch (error) {
      input.destroy();
      sandbox.dispose();
      this.renderShell();
      throw error;
    }
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
    (requireElement(this.root, '.capture-shot') as HTMLButtonElement).addEventListener(
      'click',
      () => {
        const last = capturedFrames.at(-1);
        if (last === undefined) return;
        const scale = Number(
          (requireElement(this.root, '.capture-scale') as HTMLSelectElement).value,
        );
        const image = scaleRgba(indexedFrame(last), scale);
        downloadBytes(
          `${project.id}-${String(capturedInputs.at(-1)?.frame ?? 0).padStart(5, '0')}@${String(scale)}x.png`,
          encodeRgbaPng(image.width, image.height, image.rgba),
          'image/png',
        );
      },
    );
    (requireElement(this.root, '.capture-gif') as HTMLButtonElement).addEventListener(
      'click',
      () => {
        status.textContent = 'GIF ENCODING 30FPS';
        const sampled = capturedFrames.filter(
          (_frame, index) => index % 2 === capturedFrames.length % 2,
        );
        if (sampled.length === 0) return;
        downloadBytes(`${project.id}.gif`, encodeIndexedGif(sampled.slice(-150)), 'image/gif');
        status.textContent = `GIF SAVED ${String(Math.min(150, sampled.length))}F`;
      },
    );
    (requireElement(this.root, '.capture-replay') as HTMLButtonElement).addEventListener(
      'click',
      () => {
        downloadBytes(`${project.id}.pxrec`, encodeReplayTrace(capturedInputs), 'application/json');
      },
    );
    (requireElement(this.root, '.replay-input') as HTMLInputElement).addEventListener(
      'change',
      (event) => {
        const file = (event.currentTarget as HTMLInputElement).files?.[0];
        if (file === undefined) return;
        void (async () => {
          if (file.size > REPLAY_MAX_BYTES) throw new RangeError('replay byte length is invalid');
          const trace = decodeReplayTrace(new Uint8Array(await file.arrayBuffer()));
          stop();
          await this.runProject(trace);
          const replayStatus = this.root.querySelector<HTMLElement>('.player-status');
          if (replayStatus !== null)
            replayStatus.textContent = `PXREC ${String(trace.frames.length)}F`;
        })().catch((error: unknown) => {
          status.textContent = errorMessage(error);
          status.classList.add('error');
        });
      },
    );
    globalThis.addEventListener('keydown', stopKey, true);
    const frame = async (): Promise<void> => {
      if (stopped) {
        return;
      }
      try {
        const inputFrame =
          importedInputs?.get(frameCursor) ??
          (importedInputs === undefined ? input.poll() : emptyInputFrame());
        const result = await sandbox.frame(inputFrame);
        this.capturedFrames.set(project.id, result.output.indexedPixels.slice());
        capturedFrames.push(result.output.indexedPixels.slice());
        capturedInputs.push({ frame: result.frame, input: inputFrame });
        frameCursor += 1;
        if (capturedFrames.length > 300) capturedFrames.shift();
        if (capturedInputs.length > 36_000) capturedInputs.shift();
        renderer.render(result.output.indexedPixels);
        audioSink?.enqueue(result.output.audio);
        if (result.saveCommit !== undefined) await saveAccess.write(result.saveCommit);
        status.textContent = `F${String(result.frame).padStart(5, '0')} W${String(result.workUnits).padStart(5, '0')} D${String(result.drawCommands.length).padStart(4, '0')} V${String(result.output.audio.activeVoices)}`;
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
    const save = await this.repository.cartridgeSave(project.id).read();
    try {
      this.activeDebugger = await openDebugger(
        this.root,
        project,
        this.compiler,
        save,
        () => {
          this.activeDebugger = undefined;
          this.appendLines([`DEBUG STOPPED ${project.id}`]);
          this.renderShell();
        },
        () => {
          this.activeDebugger = undefined;
          this.openManual('HARDWARE');
        },
      );
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

  private async exportCartridgePng(): Promise<void> {
    const project = this.requireProject();
    const manifest = await this.compiler.parseManifest(project.manifest);
    const cartridge = await this.compiler.packProject(project.manifest, project.files);
    const identity = decodeIdentity(project.files['presentation/cartridge.json']);
    const frame = this.capturedFrames.get(project.id);
    const png = encodeCartridgePng(
      cartridge,
      {
        title: manifest.title,
        author: manifest.author,
        year: identity.year,
        players: identity.players,
        controls: identity.controls,
      },
      frame === undefined ? undefined : indexedFrame(frame),
    );
    downloadBytes(`${project.id}.pxc.png`, png, 'image/png');
    this.appendLines([
      `CART IMAGE ${project.id}.pxc.png ${String(png.byteLength)} BYTES`,
      frame === undefined
        ? 'LABEL USED FACTORY SCREEN / RUN TO CAPTURE FRAME'
        : 'LABEL CAPTURED LAST RUN FRAME',
    ]);
  }

  private async exportHtml(): Promise<void> {
    const project = this.requireProject();
    const html = await this.compiler.exportHtml(project.manifest, project.files);
    const url = URL.createObjectURL(new Blob([html], { type: 'text/html;charset=utf-8' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = `${project.id}.html`;
    link.click();
    URL.revokeObjectURL(url);
    this.appendLines([
      `EXPORTED ${project.id}.html ${String(encoder.encode(html).byteLength)} BYTES`,
    ]);
  }

  private async exportZip(): Promise<void> {
    const project = this.requireProject();
    const html = await this.compiler.exportHtml(project.manifest, project.files);
    const zip = encodeSingleFileZip('index.html', encoder.encode(html));
    downloadBytes(`${project.id}-itch.zip`, zip, 'application/zip');
    this.appendLines([
      `EXPORTED ${project.id}-itch.zip ${String(zip.byteLength)} BYTES / INDEX.HTML`,
    ]);
  }

  private async openShelf(): Promise<void> {
    this.stopPlayer();
    const projects = await this.repository.listProjects();
    const removed = await this.repository.removedProjects();
    const items = await Promise.all(
      projects.map(async (project) => {
        const [manifest, state, save, cartridge] = await Promise.all([
          this.compiler.parseManifest(project.manifest),
          this.repository.shelfState(project.id),
          this.repository.hasCartridgeSave(project.id),
          this.compiler.packProject(project.manifest, project.files),
        ]);
        const identity = decodeIdentity(project.files['presentation/cartridge.json']);
        return {
          project,
          manifest,
          state,
          save,
          bytes: cartridge.byteLength,
          players: identity.players,
          label: shelfLabel(project, manifest.label, state.origin),
        };
      }),
    );
    items.sort(
      (left, right) =>
        Number(right.state.favorite) - Number(left.state.favorite) ||
        (right.state.lastPlayed ?? 0) - (left.state.lastPlayed ?? 0) ||
        left.project.id.localeCompare(right.project.id),
    );
    this.root.innerHTML = `
      <section class="display shelf" data-view="shelf" aria-label="PX-240C Cart Bay">
        <header class="system-bar"><span>PX-240C CART BAY</span><span>${String(items.length)} LIVE / ${String(removed.length)} BIN</span></header>
        <main class="shelf-list" role="listbox" aria-label="Local cartridges">
          ${items
            .map(
              (item, index) =>
                `<button type="button" class="shelf-item" role="option" data-id="${item.project.id}" aria-selected="${String(index === 0)}">${item.label === undefined ? '<span class="shelf-label">PX</span>' : `<img alt="${escapeHtml(item.project.title)} label" src="${item.label}">`}<span><strong>${item.state.favorite ? '★ ' : ''}${escapeHtml(item.project.title)}</strong><small>${item.project.id} / ${sizeClass(item.bytes)} / ${String(item.players)}P${item.save ? ' / SAVE' : ''} / ${item.state.origin.toUpperCase()}</small></span></button>`,
            )
            .join('')}
          ${removed
            .map(
              (item) =>
                `<button type="button" class="shelf-item removed" role="option" data-id="${item.project.id}" data-removed="true" aria-selected="false"><span class="shelf-label">BIN</span><span><strong>${escapeHtml(item.project.title)}</strong><small>${item.project.id} / RECOVERABLE</small></span></button>`,
            )
            .join('')}
        </main>
        <p class="shelf-status" role="status">LOCAL ONLY / OFFLINE</p>
        <footer class="shelf-actions"><button data-shelf="play">PLAY</button><button data-shelf="source">SOURCE</button><button data-shelf="copy">COPY</button><button data-shelf="rename">NAME</button><button data-shelf="favorite">STAR</button><button data-shelf="export">OUT</button><button data-shelf="remove">REMOVE</button><button data-shelf="back">BACK</button></footer>
      </section>
    `;
    let selected = this.root.querySelector<HTMLElement>('.shelf-item');
    let confirmation: string | undefined;
    for (const element of this.root.querySelectorAll<HTMLElement>('.shelf-item')) {
      element.addEventListener('click', () => {
        for (const option of this.root.querySelectorAll<HTMLElement>('.shelf-item'))
          option.setAttribute('aria-selected', String(option === element));
        selected = element;
        confirmation = undefined;
        const remove = this.root.querySelector<HTMLButtonElement>('[data-shelf="remove"]');
        if (remove !== null)
          remove.textContent = element.dataset.removed === 'true' ? 'RESTORE' : 'REMOVE';
      });
    }
    const selectedId = (): string => {
      const id = selected?.dataset.id;
      if (id === undefined) throw new Error('CART BAY IS EMPTY');
      return id;
    };
    const liveProject = async (): Promise<WorkingProject> => {
      const id = selectedId();
      if (selected?.dataset.removed === 'true') throw new Error('RESTORE CARTRIDGE FIRST');
      const project = await this.repository.loadProject(id);
      if (project === undefined) throw new Error('CARTRIDGE IS NO LONGER PRESENT');
      return fromStored(project);
    };
    const act = async (action: string): Promise<void> => {
      if (action === 'back') {
        this.renderShell();
        return;
      }
      const id = selectedId();
      if (action === 'remove' && selected?.dataset.removed === 'true') {
        const restored = await this.repository.restoreRemovedProject(id);
        this.activeProject = fromStored(restored);
        this.appendLines([`RESTORED ${id} FROM CART BAY BIN`]);
        await this.openShelf();
        return;
      }
      if (action === 'remove') {
        if (confirmation !== id) {
          confirmation = id;
          const status = requireElement(this.root, '.shelf-status');
          status.textContent = `CONFIRM REMOVE ${id.toUpperCase()} / RECOVERABLE`;
          const button = requireElement(this.root, '[data-shelf="remove"]');
          button.textContent = 'CONFIRM';
          return;
        }
        await this.repository.removeProjectRecoverably(id);
        if (this.activeProject?.id === id) this.activeProject = undefined;
        this.appendLines([`REMOVED ${id} TO CART BAY BIN`]);
        await this.openShelf();
        return;
      }
      const project = await liveProject();
      if (action === 'play') {
        this.activeProject = project;
        await this.runProject();
      } else if (action === 'source') {
        this.activeProject = project;
        await this.openInspector();
      } else if (action === 'export') {
        this.activeProject = project;
        await this.packProject();
        await this.openShelf();
      } else if (action === 'favorite') {
        const state = await this.repository.shelfState(id);
        await this.repository.saveShelfState(id, { ...state, favorite: !state.favorite });
        await this.openShelf();
      } else if (action === 'copy') {
        const copy = await this.duplicateShelfProject(project);
        this.activeProject = copy;
        this.appendLines([`DUPLICATED ${id} AS ${copy.id}`]);
        await this.openShelf();
      } else if (action === 'rename') {
        this.openShelfRename(project);
      }
    };
    for (const button of this.root.querySelectorAll<HTMLButtonElement>('[data-shelf]')) {
      button.addEventListener('click', () => {
        void act(button.dataset.shelf ?? '').catch((error: unknown) => {
          const status = this.root.querySelector<HTMLElement>('.shelf-status');
          if (status !== null) status.textContent = errorMessage(error);
        });
      });
    }
    selected?.focus();
  }

  private async duplicateShelfProject(project: WorkingProject): Promise<WorkingProject> {
    let suffix = 1;
    let id = `${project.id}.copy`;
    while (
      (await this.repository.loadProject(id)) !== undefined ||
      (await this.repository.isProjectRemoved(id))
    ) {
      suffix += 1;
      id = `${project.id.slice(0, Math.max(3, 58 - String(suffix).length))}.copy${String(suffix)}`;
    }
    const title = `${project.title} COPY`.slice(0, 64);
    const manifest = replaceManifestIdentity(project.manifest, id, title);
    const stored = await this.repository.saveProject({ id, title, manifest, files: project.files });
    await this.repository.setShelfOrigin(id, 'duplicate');
    return fromStored(stored);
  }

  private openShelfRename(project: WorkingProject): void {
    this.root.innerHTML = `
      <section class="display shelf-rename" data-view="shelf-rename" aria-label="Rename cartridge title">
        <header class="system-bar"><span>CART NAMEPLATE</span><span>${project.id.toUpperCase()}</span></header>
        <form><label>TITLE <input name="title" maxlength="64" value="${escapeHtml(project.title)}"></label><button type="submit">SAVE NAME</button><button type="button" data-cancel>BACK</button><p role="status">ID AND SAVE KEY STAY ${project.id.toUpperCase()}</p></form>
      </section>
    `;
    const form = requireElement(this.root, 'form') as HTMLFormElement;
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      void (async () => {
        const title = (requireElement(form, '[name="title"]') as HTMLInputElement).value
          .trim()
          .slice(0, 64);
        if (title.length === 0 || !/^[\x20-\x7e]+$/.test(title))
          throw new TypeError('TITLE MUST BE 1-64 ASCII CHARACTERS');
        const manifest = replaceManifestIdentity(project.manifest, project.id, title);
        const stored = await this.repository.saveProject({ ...project, title, manifest });
        this.activeProject = fromStored(stored);
        this.appendLines([`RENAMED ${project.id} / SAVE ID UNCHANGED`]);
        await this.openShelf();
      })().catch((error: unknown) => {
        const status = this.root.querySelector<HTMLElement>('[role="status"]');
        if (status !== null) status.textContent = errorMessage(error);
      });
    });
    this.root
      .querySelector('[data-cancel]')
      ?.addEventListener('click', () => void this.openShelf());
    (requireElement(this.root, '[name="title"]') as HTMLInputElement).focus();
  }

  private async openShare(): Promise<void> {
    const project = this.requireProject();
    const cartridge = await this.compiler.packProject(project.manifest, project.files);
    const fragment = encodeCartridgeFragment(cartridge);
    const url = new URL(location.href);
    url.hash = fragment;
    this.root.innerHTML = `
      <section class="display share-view" data-view="share" aria-label="Tiny cartridge fragment share">
        <header class="system-bar"><span>TINY CART LINK</span><span>${String(cartridge.byteLength)}B</span></header>
        <main><p>FRAGMENT ONLY / NO UPLOAD</p><p>${String(fragment.length)} / 8192 CHARACTERS</p><textarea class="share-url" readonly aria-label="Cartridge share URL"></textarea><button class="share-copy" type="button">COPY LINK</button><p class="share-status" role="status">READY</p></main>
        <footer class="tool-bar"><button type="button" data-back>ESC BACK</button></footer>
      </section>
    `;
    const text = requireElement(this.root, '.share-url') as HTMLTextAreaElement;
    text.value = url.href;
    const back = (): void => {
      this.renderShell();
    };
    this.root.querySelector('[data-back]')?.addEventListener('click', back);
    this.root.querySelector('.share-copy')?.addEventListener('click', () => {
      text.select();
      void navigator.clipboard
        .writeText(text.value)
        .then(() => {
          const status = this.root.querySelector<HTMLElement>('.share-status');
          if (status !== null) status.textContent = 'COPIED';
        })
        .catch(() => {
          const status = this.root.querySelector<HTMLElement>('.share-status');
          if (status !== null) status.textContent = 'SELECTED / COPY MANUALLY';
        });
    });
    this.root.querySelector('[data-view="share"]')?.addEventListener('keydown', (event) => {
      if ((event as KeyboardEvent).key === 'Escape') back();
    });
    text.focus();
  }

  private async info(): Promise<void> {
    const identity = await this.compiler.identity();
    const project = this.activeProject;
    const detail =
      project === undefined
        ? undefined
        : await this.compiler.packProject(project.manifest, project.files).then(async (packed) => {
            const [manifest, decoded, compilation] = await Promise.all([
              this.compiler.parseManifest(project.manifest),
              this.compiler.decodeCartridge(packed),
              this.compiler.compileProject(project.manifest, project.files, false),
            ]);
            return projectSizeReport(packed, decoded.entries, manifest, compilation);
          });
    this.appendLines([
      `${identity.language} COMPILER ${identity.compiler}`,
      project === undefined
        ? 'NO CARTRIDGE LOADED'
        : `${project.id} / ${project.title} / R${String(project.revision)}`,
      '240X144 / 32 COLOR / 60HZ',
      ...(detail === undefined
        ? []
        : [
            `${detail.sizeClass} ${String(detail.canonicalCartridgeBytes)}B / SRC ${String(detail.sourceBytes)} / GEN ${String(detail.generatedReleaseBytes)}`,
            `VIS ${String(detail.visualBytes)} MAP ${String(detail.mapBytes)} FONT ${String(detail.fontBytes)} AUDIO ${String(detail.audioBytes)}`,
            `META ${String(detail.metadataBytes)} OVER ${String(detail.containerOverheadBytes)} GAIN ${String(detail.compressionGainBytes)}`,
            `SAVE 8192 / ${detail.warning}`,
          ]),
    ]);
  }

  private async refreshActiveCartMeter(
    target: HTMLElement,
    project: WorkingProject,
  ): Promise<void> {
    try {
      const bytes = await this.compiler.packProject(project.manifest, project.files);
      if (
        this.activeProject?.id === project.id &&
        this.activeProject.revision === project.revision
      ) {
        target.textContent = `${project.id.toUpperCase()} ${String(bytes.byteLength)}B/${sizeClass(bytes.byteLength)}`;
      }
    } catch {
      if (this.activeProject?.id === project.id)
        target.textContent = `${project.id.toUpperCase()} !BUILD`;
    }
  }

  private async openInspector(): Promise<void> {
    const project = this.requireProject();
    const cartridge = await this.compiler.decodeCartridge(
      await this.compiler.packProject(project.manifest, project.files),
    );
    const sources = Object.entries(cartridge.entries)
      .filter(([path]) => path.startsWith('source/'))
      .sort(([left], [right]) => left.localeCompare(right));
    this.root.innerHTML = `
      <section class="display cartridge-inspector" data-view="inspector" aria-label="Packed cartridge inspector">
        <header class="system-bar"><span>PXC INSPECTOR</span><span>SOURCE VISIBLE</span></header>
        <nav class="inspector-files" aria-label="Cartridge contents"></nav>
        <pre class="inspector-output" tabindex="0"></pre>
        <footer class="tool-bar"><button type="button" data-back>ESC BACK</button></footer>
      </section>
    `;
    const navigation = requireElement(this.root, '.inspector-files');
    const output = requireElement(this.root, '.inspector-output');
    const panes = new Map<string, string>([
      ['MANIFEST', JSON.stringify(cartridge.manifest, undefined, 2)],
      ...sources.map(
        ([path, bytes]) =>
          [path.slice('source/'.length), decoder.decode(Uint8Array.from(bytes))] as [
            string,
            string,
          ],
      ),
    ]);
    for (const [name, contents] of panes) {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = name;
      button.addEventListener('click', () => {
        output.textContent = contents;
      });
      navigation.append(button);
    }
    output.textContent = panes.get('MANIFEST') ?? '';
    const back = (): void => {
      this.renderShell();
    };
    this.root.querySelector('[data-back]')?.addEventListener('click', back);
    this.root.querySelector('[data-view="inspector"]')?.addEventListener('keydown', (event) => {
      if ((event as KeyboardEvent).key === 'Escape') back();
    });
    (output as HTMLElement).focus();
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
    const cart = this.root.querySelector<HTMLElement>('.active-cart');
    if (cart !== null) {
      cart.textContent = this.activeProject?.id.toUpperCase() ?? 'NO CART';
    }
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

function splitCommand(source: string): string[] {
  const result: string[] = [];
  for (const match of source.matchAll(/"([^"]*)"|'([^']*)'|(\S+)/g)) {
    result.push(match[1] ?? match[2] ?? match[3] ?? '');
  }
  return result;
}

const COMPLETIONS = [
  'import',
  'pub',
  'private',
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
  'font_print',
  'btn',
  'btnp',
  'rng_int',
  'rng_num',
  'sfx',
  'music',
  'save_get_int',
  'save_set_int',
  'save_commit',
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
    /\/\/.*$|"(?:\\.|[^"\\])*"|#[A-Za-z_][A-Za-z0-9_]*|\b(?:and|as|assert|break|case|const|continue|draw|elif|else|enum|false|fn|for|if|import|in|let|match|none|not|on|or|private|pub|raster|record|return|start|state|task|true|update|var|wait|while)\b|\b\d+(?:\.\d+)?(?:f|s)?\b/gm;
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
      body: 'PXCL/1 is ASCII-only, statically typed, indentation-based, and deterministic. Mutable top-level values use state with an explicit type. Arrays and Lists have fixed checked capacities; use none/some/is_some/unwrap_or with Option values.',
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
      body: 'Use clear, pixel, line, rect/rect_fill, circle/circle_fill, triangle, sprite/sprite_xform, animation, map/map_cell/map_flag, print/font_print, camera, clip, pal, dither, and raster_scroll. FONT edits custom glyphs; print keeps the fixed system font. Colors are fixed indices 0-31.',
    },
    {
      title: 'INPUT',
      body: 'btn and btnp accept pad1 through pad4 and button values up/down/left/right/a/b/x/y/l/r/start_button/menu. pointer_x/y, pointer_inside, and pointer_primary/secondary expose recorded mouse, pen, and touch input.',
    },
    {
      title: 'AUDIO',
      body: 'SFX are eight-voice oscillator patches. MUSIC opens the eight-channel pattern tracker. Imported PCM and arbitrary samples are unavailable.',
    },
    {
      title: 'DEBUG',
      body: 'DEBUG opens frame pause, source breakpoints, trace stepping, watches, state/task/profile/hardware inspectors, and deterministic rewind. Debug save writes are not persisted.',
    },
    {
      title: 'HARDWARE',
      body: 'Hardware Revision 1 uses a 22-bit byte bus. In DEBUG choose MEMO, enter a hexadecimal address and 1-64 byte length, then GET. HEX/DEC changes display and SET edits one writable byte while paused. WP adds up to eight change watchpoints. RAM begins 000000, framebuffers 010000, visual store 030000, registers 050000, save 058000, cartridge ROM 060000. Reserved bytes read zero and reject writes.',
    },
    {
      title: 'LIMITS',
      body: '240x144, 32 colors, 128 KiB visual assets, 8 KiB save, 256 KiB packed cartridge, 50,000 work units, 4096 draw commands, 8 synth voices, 4 local ports.',
    },
    {
      title: 'ARTIFACTS',
      body: 'PACK downloads raw source-visible .pxc. CART downloads the PX-240C cartridge-object .pxc.png with the same complete bytes and project identity metadata; run first to use the last game frame as its label. EXPORT writes the single-file offline HTML player.',
    },
  ];
}

function decodeIdentity(bytes: Uint8Array | undefined): {
  readonly year: number;
  readonly players: number;
  readonly controls: string;
} {
  if (bytes !== undefined) {
    try {
      const value: unknown = JSON.parse(decoder.decode(bytes));
      if (
        typeof value === 'object' &&
        value !== null &&
        'revision' in value &&
        value.revision === 1 &&
        'year' in value &&
        typeof value.year === 'number' &&
        Number.isSafeInteger(value.year) &&
        value.year >= 1970 &&
        value.year <= 9999 &&
        'players' in value &&
        typeof value.players === 'number' &&
        Number.isSafeInteger(value.players) &&
        value.players >= 1 &&
        value.players <= 4 &&
        'controls' in value &&
        typeof value.controls === 'string' &&
        value.controls.length <= 64
      )
        return { year: value.year, players: value.players, controls: value.controls };
    } catch {
      // A malformed optional identity file falls back without blocking raw project access.
    }
  }
  return { year: 1999, players: 1, controls: 'PAD' };
}

function indexedFrame(indexed: Uint8Array): DecodedPng {
  if (indexed.length !== HARDWARE.width * HARDWARE.height)
    throw new RangeError('captured framebuffer dimensions are invalid');
  const rgba = new Uint8Array(indexed.length * 4);
  for (let pixel = 0; pixel < indexed.length; pixel += 1) {
    const color = (indexed[pixel] ?? 0) * 4;
    rgba[pixel * 4] = MASTER_PALETTE_RGBA[color] ?? 0;
    rgba[pixel * 4 + 1] = MASTER_PALETTE_RGBA[color + 1] ?? 0;
    rgba[pixel * 4 + 2] = MASTER_PALETTE_RGBA[color + 2] ?? 0;
    rgba[pixel * 4 + 3] = 255;
  }
  return { width: HARDWARE.width, height: HARDWARE.height, rgba };
}

function scaleRgba(image: DecodedPng, scale: number): DecodedPng {
  if (!Number.isSafeInteger(scale) || scale < 1 || scale > 4)
    throw new RangeError('capture scale must be 1-4');
  const width = image.width * scale;
  const height = image.height * scale;
  const rgba = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const source = (Math.floor(y / scale) * image.width + Math.floor(x / scale)) * 4;
      rgba.set(image.rgba.subarray(source, source + 4), (y * width + x) * 4);
    }
  }
  return { width, height, rgba };
}

function sizeClass(bytes: number): '4K' | '16K' | '64K' | '256K' {
  if (bytes <= 4_096) return '4K';
  if (bytes <= 16_384) return '16K';
  if (bytes <= 65_536) return '64K';
  return '256K';
}

interface ProjectSizeReport {
  readonly sizeClass: '4K' | '16K' | '64K' | '256K';
  readonly canonicalCartridgeBytes: number;
  readonly sourceBytes: number;
  readonly generatedReleaseBytes: number;
  readonly visualBytes: number;
  readonly mapBytes: number;
  readonly fontBytes: number;
  readonly audioBytes: number;
  readonly metadataBytes: number;
  readonly containerOverheadBytes: number;
  readonly compressionGainBytes: number;
  readonly saveAllocationBytes: 8192;
  readonly largestEntries: readonly { readonly path: string; readonly bytes: number }[];
  readonly largestSymbols: readonly {
    readonly name: string;
    readonly kind: string;
    readonly definitionBytes: number;
  }[];
  readonly warning: string;
}

function projectSizeReport(
  packed: Uint8Array,
  entries: Readonly<Record<string, readonly number[]>>,
  manifest: ProjectManifest,
  compilation: CompilationResult,
): ProjectSizeReport {
  const encoded = archiveEncodedBytes(packed);
  let sourceBytes = 0;
  let visualBytes = 0;
  let mapBytes = 0;
  let fontBytes = 0;
  let audioBytes = 0;
  let metadataBytes = 0;
  for (const [path, bytes] of Object.entries(entries)) {
    if (path.startsWith('source/')) sourceBytes += bytes.length;
    if (path === 'manifest.json' || path.startsWith('presentation/')) metadataBytes += bytes.length;
  }
  for (const asset of Object.values(manifest.assets)) {
    const archivePath = `assets/${asset.path}`;
    const bytes = entries[archivePath]?.length ?? 0;
    if (asset.kind === 'map') {
      mapBytes += bytes;
      visualBytes += bytes;
    } else if (asset.kind === 'font') {
      fontBytes += bytes;
      visualBytes += bytes;
    } else if (asset.kind === 'sound' || asset.kind === 'music') {
      audioBytes += bytes;
    } else {
      visualBytes += bytes;
    }
  }
  const rawArchiveBytes = Object.values(entries).reduce((total, bytes) => total + bytes.length, 0);
  const generatedReleaseBytes = compilation.generated?.generated_bytes ?? 0;
  const work = Object.values(compilation.generated?.work_model ?? {}).reduce(
    (total, value) => total + value,
    0,
  );
  const warning =
    packed.length > 196_608
      ? 'PACK >75%; INSPECT LARGEST ENTRY'
      : visualBytes > 98_304
        ? 'VISUAL >75%; TRIM LARGEST ASSET'
        : work > 40_000
          ? 'STATIC WORK MODEL HIGH; PROFILE RUN'
          : 'BUDGETS WITHIN FIXED LIMITS';
  return {
    sizeClass: sizeClass(packed.length),
    canonicalCartridgeBytes: packed.length,
    sourceBytes,
    generatedReleaseBytes,
    visualBytes,
    mapBytes,
    fontBytes,
    audioBytes,
    metadataBytes,
    containerOverheadBytes: packed.length - encoded,
    compressionGainBytes: rawArchiveBytes - encoded,
    saveAllocationBytes: 8192,
    largestEntries: Object.entries(entries)
      .map(([path, bytes]) => ({ path, bytes: bytes.length }))
      .sort((left, right) => right.bytes - left.bytes || left.path.localeCompare(right.path))
      .slice(0, 8),
    largestSymbols: compilation.analysis.symbols
      .filter((symbol) => symbol.defined_at !== undefined)
      .map((symbol) => ({
        name: symbol.name,
        kind: symbol.kind,
        definitionBytes: (symbol.defined_at?.end ?? 0) - (symbol.defined_at?.start ?? 0),
      }))
      .sort(
        (left, right) =>
          right.definitionBytes - left.definitionBytes || left.name.localeCompare(right.name),
      )
      .slice(0, 8),
    warning,
  };
}

function archiveEncodedBytes(bytes: Uint8Array): number {
  if (bytes.length < 12) throw new TypeError('PXC HEADER IS TRUNCATED');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const count = view.getUint32(8, true);
  let cursor = 12;
  let encoded = 0;
  for (let index = 0; index < count; index += 1) {
    if (cursor + 42 > bytes.length) throw new TypeError('PXC ENTRY HEADER IS TRUNCATED');
    const pathLength = view.getUint16(cursor, true);
    const encodedLength = view.getUint32(cursor + 6, true);
    cursor += 42;
    const end = cursor + pathLength + encodedLength;
    if (!Number.isSafeInteger(end) || end > bytes.length)
      throw new TypeError('PXC ENTRY IS TRUNCATED');
    encoded += encodedLength;
    cursor = end;
  }
  if (cursor !== bytes.length) throw new TypeError('PXC HAS TRAILING DATA');
  return encoded;
}

function shelfLabel(
  project: WorkingProject,
  path: string | null,
  origin: 'bundled' | 'created' | 'imported' | 'fragment' | 'duplicate',
): string | undefined {
  if (path === null) return undefined;
  const bytes = project.files[path];
  if (bytes === undefined || bytes.length > 256 * 1024) return undefined;
  const png =
    bytes.length >= 8 &&
    [137, 80, 78, 71, 13, 10, 26, 10].every((byte, index) => bytes[index] === byte);
  const trustedSvg = origin === 'bundled' && path.endsWith('.svg');
  if (!png && !trustedSvg) return undefined;
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return `data:${png ? 'image/png' : 'image/svg+xml'};base64,${btoa(binary)}`;
}

function replaceManifestIdentity(manifest: string, id: string, title: string): string {
  if (!PROJECT_ID.test(id)) throw new TypeError('duplicate cartridge id is invalid');
  const idMatches = manifest.match(/^id\s*=.*$/gm);
  const titleMatches = manifest.match(/^title\s*=.*$/gm);
  if (idMatches?.length !== 1 || titleMatches?.length !== 1)
    throw new TypeError('manifest identity is ambiguous');
  return manifest
    .replace(/^id\s*=.*$/m, `id = ${JSON.stringify(id)}`)
    .replace(/^title\s*=.*$/m, `title = ${JSON.stringify(title)}`);
}

function escapeHtml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function downloadBytes(name: string, bytes: Uint8Array, type: string): void {
  const buffer = new Uint8Array(bytes).buffer;
  const url = URL.createObjectURL(new Blob([buffer], { type }));
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  link.click();
  URL.revokeObjectURL(url);
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
