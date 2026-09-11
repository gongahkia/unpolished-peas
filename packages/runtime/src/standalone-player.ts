import InlineSandboxWorker from './sandbox-worker?worker&inline';

import { WebAudioSink } from './audio';
import type { ProjectAssetDeclaration } from './asset-codec';
import { WebGlIndexedRenderer } from './graphics';
import { HARDWARE } from './hardware';
import { BrowserInput } from './input';
import { SandboxSession } from './sandbox';

interface StandalonePayload {
  readonly manifest: {
    readonly id: string;
    readonly title: string;
    readonly author: string;
    readonly updateRate: 30 | 60;
    readonly display: string | null;
    readonly assets: Readonly<Record<string, ProjectAssetDeclaration>>;
  };
  readonly presentation: {
    readonly year: number;
    readonly players: number;
    readonly controls: string;
  };
  readonly files: Readonly<Record<string, string>>;
  readonly rom: string;
}

declare global {
  var __PX240C_CARTRIDGE__: StandalonePayload;
}

const payload = globalThis.__PX240C_CARTRIDGE__;
const canvas = requireElement('#screen') as HTMLCanvasElement;
const status = requireElement('#status') as HTMLOutputElement;
const soundButton = requireElement('#sound') as HTMLButtonElement;
const pauseButton = requireElement('#pause') as HTMLButtonElement;
const resetButton = requireElement('#reset') as HTMLButtonElement;
const fullscreenButton = requireElement('#fullscreen') as HTMLButtonElement;
const sourceButton = requireElement('#source') as HTMLButtonElement;
const inspector = requireElement('#inspector') as HTMLElement;
const sourceSelect = requireElement('#source-file') as HTMLSelectElement;
const sourceView = requireElement('#source-view') as HTMLElement;
const files = Object.fromEntries(
  Object.entries(payload.files).map(([path, value]) => [path, decodeBase64(value)]),
);
const sourceEntries = Object.keys(files)
  .filter((path) => path.startsWith('source/'))
  .sort();

for (const path of sourceEntries) {
  const option = document.createElement('option');
  option.value = path;
  option.textContent = path.slice('source/'.length);
  sourceSelect.append(option);
}
const showSource = (): void => {
  const path = sourceSelect.value || sourceEntries[0];
  sourceView.textContent = path === undefined ? 'NO SOURCE' : new TextDecoder().decode(files[path]);
};
sourceSelect.addEventListener('change', showSource);
sourceButton.addEventListener('click', () => {
  inspector.hidden = !inspector.hidden;
  sourceButton.textContent = inspector.hidden ? 'SOURCE' : 'PLAY';
  showSource();
});
(requireElement('#close-source') as HTMLButtonElement).addEventListener('click', () => {
  inspector.hidden = true;
  sourceButton.textContent = 'SOURCE';
});

const renderer = new WebGlIndexedRenderer(canvas);
let sandbox: SandboxSession | undefined;
let input: BrowserInput | undefined;
let audio: WebAudioSink | undefined;
let stopped = false;
let paused = false;
let generation = 0;

document.documentElement.dataset.embed = String(location.hash === '#embed');

soundButton.addEventListener('click', () => {
  audio = new WebAudioSink();
  void audio.resume().then(() => {
    soundButton.textContent = 'SOUND ON';
    soundButton.disabled = true;
  });
});

pauseButton.addEventListener('click', () => {
  paused = !paused;
  pauseButton.textContent = paused ? 'RESUME' : 'PAUSE';
  if (paused) {
    status.textContent = 'PAUSED';
    void closeAudio();
  }
});

resetButton.addEventListener('click', () => {
  void restart().catch(showError);
});

fullscreenButton.addEventListener('click', () => {
  void document.querySelector('.unit')?.requestFullscreen();
});

globalThis.addEventListener('pagehide', () => {
  stopped = true;
  generation += 1;
  input?.destroy();
  sandbox?.dispose();
  if (audio !== undefined) void audio.close();
});

void restart().catch(showError);

async function restart(): Promise<void> {
  generation += 1;
  const currentGeneration = generation;
  input?.destroy();
  sandbox?.dispose();
  await closeAudio();
  stopped = false;
  paused = false;
  pauseButton.textContent = 'PAUSE';
  soundButton.textContent = 'SOUND';
  soundButton.disabled = false;
  const nextWorker = new InlineSandboxWorker({
    name: `px240c-standalone-${payload.manifest.id}-${String(currentGeneration)}`,
  });
  const nextSandbox = new SandboxSession(nextWorker, 1_000);
  const nextInput = new BrowserInput(canvas);
  sandbox = nextSandbox;
  input = nextInput;
  const javascript = new TextDecoder().decode(requireFile('build/cartridge.js'));
  const rom = decodeBase64(payload.rom);
  await nextSandbox.load(javascript, {
    seed: 0x240c1999,
    workUnitsPerFrame: HARDWARE.workUnitsPerFrame,
    updateRate: payload.manifest.updateRate,
    assets: {
      declarations: payload.manifest.assets,
      files,
      displayPath: payload.manifest.display,
    },
    save: readSave(),
    rom,
  });
  canvas.focus();
  requestAnimationFrame(() => void frame(currentGeneration, nextSandbox, nextInput));
}

async function frame(
  currentGeneration: number,
  currentSandbox: SandboxSession,
  currentInput: BrowserInput,
): Promise<void> {
  if (stopped || currentGeneration !== generation) return;
  if (paused) {
    requestAnimationFrame(() => void frame(currentGeneration, currentSandbox, currentInput));
    return;
  }
  try {
    const result = await currentSandbox.frame(currentInput.poll());
    if (currentGeneration !== generation) return;
    renderer.render(result.output.indexedPixels);
    audio?.enqueue(result.output.audio);
    if (result.saveCommit !== undefined) writeSave(result.saveCommit);
    status.textContent = `F${String(result.frame).padStart(5, '0')} W${String(result.workUnits).padStart(5, '0')}`;
    requestAnimationFrame(() => void frame(currentGeneration, currentSandbox, currentInput));
  } catch (error: unknown) {
    stopped = true;
    showError(error);
  }
}

async function closeAudio(): Promise<void> {
  const current = audio;
  audio = undefined;
  if (current !== undefined) await current.close();
}

function readSave(): Uint8Array {
  const current = localStorage.getItem(`px240c/v1/${payload.manifest.id}`);
  if (current !== null) {
    try {
      const bytes = decodeBase64(current);
      if (bytes.length <= HARDWARE.saveCapacityBytes) return bytes;
    } catch {
      // A malformed local value is isolated to this cartridge and replaced only after a commit.
    }
  }
  const alpha = localStorage.getItem(`px240c/${payload.manifest.id}`);
  if (alpha === null) return new Uint8Array();
  try {
    const parsed: unknown = JSON.parse(alpha);
    if (!isIntegerSave(parsed)) return new Uint8Array();
    return new TextEncoder().encode(JSON.stringify(sortRecord(parsed)));
  } catch {
    return new Uint8Array();
  }
}

function writeSave(bytes: Uint8Array): void {
  localStorage.setItem(`px240c/v1/${payload.manifest.id}`, encodeBase64(bytes));
}

function isIntegerSave(value: unknown): value is Readonly<Record<string, number>> {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value) &&
    Object.keys(value).every(
      (key) =>
        /^[A-Za-z_][A-Za-z0-9_]{0,31}$/.test(key) &&
        typeof (value as Record<string, unknown>)[key] === 'number' &&
        Number.isSafeInteger((value as Record<string, unknown>)[key]),
    )
  );
}

function sortRecord(value: Readonly<Record<string, number>>): Readonly<Record<string, number>> {
  return Object.fromEntries(
    Object.entries(value).sort(([left], [right]) => left.localeCompare(right)),
  );
}

function requireFile(path: string): Uint8Array {
  const bytes = files[path];
  if (bytes === undefined) throw new Error(`standalone cartridge is missing '${path}'`);
  return bytes;
}

function showError(error: unknown): void {
  status.textContent = error instanceof Error ? error.message : 'PX-240C standalone failed';
  status.classList.add('error');
}

function decodeBase64(value: string): Uint8Array {
  const decoded = atob(value);
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

function encodeBase64(value: Uint8Array): string {
  let binary = '';
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function requireElement(selector: string): Element {
  const element = document.querySelector(selector);
  if (element === null) throw new Error(`standalone player is missing '${selector}'`);
  return element;
}
