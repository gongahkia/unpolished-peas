import {
  AudioAssetStore,
  emptyInputFrame,
  HARDWARE,
  IndexedDbStorage,
  RuntimeFault,
  SandboxSession,
  StudioRepository,
  Synthesizer,
  WebAudioSink,
  WebGlIndexedRenderer,
} from '@px240c/runtime';
import { StudioApp } from './studio';
import './style.css';

const studio = document.querySelector<HTMLElement>('#studio');
if (studio === null) {
  throw new Error('PX-240C studio root is missing');
}
const studioRoot = studio;

updateIntegerScale();
globalThis.addEventListener('resize', updateIntegerScale);
if ('serviceWorker' in navigator) {
  globalThis.addEventListener('load', () => {
    void navigator.serviceWorker
      .register(new URL('./sw.js', document.baseURI), { scope: './' })
      .catch((error: unknown) => {
        // A navigation can abort an otherwise successful best-effort registration.
        if (!(error instanceof DOMException && error.name === 'AbortError')) {
          console.warn('PX-240C offline cache registration failed', error);
        }
      });
  });
}

const parameters = new URLSearchParams(globalThis.location.search);
const diagnosticMode = parameters.get('sandbox-test');
const audioDiagnostic = parameters.get('hardware-test') === 'audio';
const persistenceDiagnostic = parameters.get('persistence-test') === '1';
if (diagnosticMode !== null || audioDiagnostic || persistenceDiagnostic) {
  renderDiagnosticScaffold();
} else {
  void new StudioApp(studioRoot).boot().catch((error: unknown) => {
    studioRoot.textContent = error instanceof Error ? error.message : 'PX-240C boot failed';
    document.documentElement.dataset.studioReady = 'failed';
  });
}
if (diagnosticMode !== null) {
  void runSandboxDiagnostic(diagnosticMode);
}
if (audioDiagnostic) {
  prepareAudioDiagnostic();
}
if (persistenceDiagnostic) {
  void runPersistenceDiagnostic();
}

function renderDiagnosticScaffold(): void {
  const visualKilobytes = String(HARDWARE.visualCapacityBytes / 1024);
  const audioVoices = String(HARDWARE.audioVoices);
  studioRoot.innerHTML = `
    <section class="display diagnostic-display" aria-label="PX-240C monitor">
      <canvas id="screen" aria-label="PX-240C indexed display"></canvas>
      <p>PX-240C COLOR DEVELOPMENT UNIT</p>
      <p>SYSTEM ROM 1.0&nbsp; (C) 1999</p>
      <p>${visualKilobytes}K VISUAL STORE / ${audioVoices}V SOUND</p>
      <p>PXCL/1 READY</p>
      <p class="prompt" aria-label="command prompt">&gt;<span aria-hidden="true">_</span></p>
      <button id="audio-test" type="button" hidden>ENABLE AUDIO TEST</button>
      <p id="diagnostic" class="diagnostic" role="status" aria-live="polite"></p>
    </section>
  `;
}

async function runPersistenceDiagnostic(): Promise<void> {
  const status = document.querySelector<HTMLElement>('#diagnostic');
  if (status === null) {
    throw new Error('persistence diagnostic output is missing');
  }
  const repository = new StudioRepository(new IndexedDbStorage('px240c-diagnostic'));
  const project = {
    id: 'diagnostic.project',
    title: 'DIAGNOSTIC PROJECT',
    manifest: 'format = 1',
    files: { 'src/main.pxl': new TextEncoder().encode('on draw:\n  clear(0)\n') },
  };
  const firstSave = repository.cartridgeSave('diagnostic.first');
  const secondSave = repository.cartridgeSave('diagnostic.second');
  try {
    await repository.saveProject(project);
    await repository.saveProject({
      ...project,
      files: { 'src/main.pxl': new TextEncoder().encode('on draw:\n  clear(1)\n') },
    });
    await firstSave.write(Uint8Array.of(1, 2, 3));
    await secondSave.write(Uint8Array.of(9));
    const recovery = await repository.recoverySnapshots(project.id);
    if (
      recovery.length !== 1 ||
      (await firstSave.read())[0] !== 1 ||
      (await secondSave.read())[0] !== 9
    ) {
      throw new Error('IndexedDB persistence state was incoherent');
    }
    showResult(status, 'INDEXEDDB RECOVERY / SAVE ISOLATION VERIFIED', true);
    document.documentElement.dataset.persistenceTest = 'passed';
  } catch (error: unknown) {
    showResult(
      status,
      error instanceof Error ? error.message : 'persistence diagnostic failed',
      false,
    );
    document.documentElement.dataset.persistenceTest = 'failed';
  } finally {
    await repository.deleteProject(project.id);
    await firstSave.clear();
    await secondSave.clear();
  }
}

function prepareAudioDiagnostic(): void {
  const button = document.querySelector<HTMLButtonElement>('#audio-test');
  const status = document.querySelector<HTMLElement>('#diagnostic');
  if (button === null || status === null) {
    throw new Error('audio diagnostic controls are missing');
  }
  button.hidden = false;
  button.addEventListener(
    'click',
    () => {
      void runAudioDiagnostic(button, status);
    },
    { once: true },
  );
}

async function runAudioDiagnostic(button: HTMLButtonElement, status: HTMLElement): Promise<void> {
  button.disabled = true;
  try {
    const tone = {
      kind: 'sound' as const,
      name: 'audio-check',
      waveform: 'pulse' as const,
      note: 69,
      durationFrames: 8,
      volume: 0.35,
      pan: 0,
      duty: 0.25,
      envelope: { attackFrames: 1, decayFrames: 1, sustainLevel: 0.7, releaseFrames: 2 },
      pitch: {
        slideSemitonesPerFrame: 0.1,
        vibratoDepthSemitones: 0.2,
        vibratoPeriodFrames: 4,
      },
    };
    const synthesizer = new Synthesizer(new AudioAssetStore([tone]));
    const sink = new WebAudioSink();
    await sink.resume();
    sink.enqueue(
      synthesizer.executeFrame([
        {
          name: 'sfx',
          arguments: [{ name: tone.name, kind: 'Sound' }],
          sourceSpan: { start: 0, end: 0 },
        },
      ]),
    );
    if (sink.state !== 'running') {
      throw new Error(`Web Audio remained ${sink.state}`);
    }
    globalThis.addEventListener('pagehide', () => void sink.close(), { once: true });
    showResult(status, '8V SYNTH / WEB AUDIO VERIFIED', true);
    document.documentElement.dataset.hardwareAudio = 'passed';
  } catch (error: unknown) {
    showResult(status, error instanceof Error ? error.message : 'audio diagnostic failed', false);
    document.documentElement.dataset.hardwareAudio = 'failed';
  }
}

async function runSandboxDiagnostic(mode: string): Promise<void> {
  const status = document.querySelector<HTMLElement>('#diagnostic');
  if (status === null) {
    throw new Error('sandbox diagnostic output is missing');
  }
  const worker = new Worker(
    new URL('../../../packages/runtime/src/sandbox-worker.ts', import.meta.url),
    { type: 'module', name: 'px240c-cartridge' },
  );
  const sandbox = new SandboxSession(worker, 1_000);
  try {
    const audit = await sandbox.audit();
    if (audit.exposedCapabilities.length > 0 || audit.mathRandomAvailable) {
      throw new Error(`worker capability lockdown failed: ${audit.exposedCapabilities.join(', ')}`);
    }
    if (mode === 'capabilities') {
      showResult(status, 'SANDBOX CAPABILITIES DENIED', true);
      return;
    }

    const fixture = mode === 'runaway' ? 'sandbox-runaway.js' : 'sandbox-smoke.js';
    const response = await fetch(`./generated/${fixture}`);
    if (!response.ok) {
      throw new Error(`sandbox fixture failed to load: ${String(response.status)}`);
    }
    await sandbox.load(await response.text(), {
      seed: 0x240c1999,
      workUnitsPerFrame: mode === 'runaway' ? 96 : 20_000,
      updateRate: 60,
      ...(mode === 'runaway' ? {} : { save: { boots: 4 } }),
    });
    if (mode === 'runaway') {
      try {
        await sandbox.frame(emptyInputFrame());
      } catch (error: unknown) {
        if (
          error instanceof RuntimeFault &&
          error.code === 'PX9001' &&
          error.sourceSpan.start > 0
        ) {
          showResult(status, 'RUNAWAY STOPPED / SOURCE MAPPED', true);
          return;
        }
        throw error;
      }
      throw new Error('runaway cartridge completed without a budget fault');
    }
    const frame = await sandbox.frame(emptyInputFrame());
    if (
      frame.frame !== 0 ||
      frame.drawCommands.length < 8 ||
      frame.workUnits <= 0 ||
      frame.saveWrites.length !== 1 ||
      frame.saveWrites[0]?.key !== 'boots' ||
      frame.saveWrites[0].value !== 5
    ) {
      throw new Error('sandbox frame result was incoherent');
    }
    const screen = document.querySelector<HTMLCanvasElement>('#screen');
    const display = document.querySelector<HTMLElement>('.display');
    if (screen === null || display === null) {
      throw new Error('hardware display is missing');
    }
    const renderer = new WebGlIndexedRenderer(screen);
    renderer.render(frame.output.indexedPixels);
    display.classList.add('running-cartridge');
    showResult(status, 'SANDBOX FRAME VERIFIED', true);
  } catch (error: unknown) {
    showResult(status, error instanceof Error ? error.message : 'sandbox diagnostic failed', false);
  } finally {
    sandbox.dispose();
  }
}

function showResult(status: HTMLElement, message: string, passed: boolean): void {
  status.textContent = message;
  status.classList.toggle('error', !passed);
  document.documentElement.dataset.sandboxTest = passed ? 'passed' : 'failed';
}

function updateIntegerScale(): void {
  const scale = Math.max(
    1,
    Math.floor(
      Math.min(globalThis.innerWidth / HARDWARE.width, globalThis.innerHeight / HARDWARE.height),
    ),
  );
  document.documentElement.style.setProperty('--px-scale', String(scale));
}
