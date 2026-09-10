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

const worker = new InlineSandboxWorker({ name: `px240c-standalone-${payload.manifest.id}` });
const sandbox = new SandboxSession(worker, 1_000);
const input = new BrowserInput(canvas);
const renderer = new WebGlIndexedRenderer(canvas);
let audio: WebAudioSink | undefined;
let stopped = false;

soundButton.addEventListener(
  'click',
  () => {
    audio = new WebAudioSink();
    void audio.resume().then(() => {
      soundButton.textContent = 'SOUND ON';
      soundButton.disabled = true;
    });
  },
  { once: true },
);

globalThis.addEventListener('pagehide', () => {
  stopped = true;
  input.destroy();
  sandbox.dispose();
  if (audio !== undefined) void audio.close();
});

void start().catch(showError);

async function start(): Promise<void> {
  const javascript = new TextDecoder().decode(requireFile('build/cartridge.js'));
  const rom = decodeBase64(payload.rom);
  await sandbox.load(javascript, {
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
  requestAnimationFrame(() => void frame());
}

async function frame(): Promise<void> {
  if (stopped) return;
  try {
    const result = await sandbox.frame(input.poll());
    renderer.render(result.output.indexedPixels);
    audio?.enqueue(result.output.audio);
    if (result.saveCommit !== undefined) writeSave(result.saveCommit);
    status.textContent = `F${String(result.frame).padStart(5, '0')} W${String(result.workUnits).padStart(5, '0')}`;
    requestAnimationFrame(() => void frame());
  } catch (error: unknown) {
    stopped = true;
    showError(error);
  }
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
