import { emptyInputFrame, HARDWARE, RuntimeFault, SandboxSession } from '@px240c/runtime';
import './style.css';

const studio = document.querySelector<HTMLElement>('#studio');
if (studio === null) {
  throw new Error('PX-240C studio root is missing');
}

const visualKilobytes = String(HARDWARE.visualCapacityBytes / 1024);
const audioVoices = String(HARDWARE.audioVoices);

studio.innerHTML = `
  <section class="display" aria-label="PX-240C monitor">
    <p>PX-240C COLOR DEVELOPMENT UNIT</p>
    <p>SYSTEM ROM 1.0&nbsp; (C) 1999</p>
    <p>${visualKilobytes}K VISUAL STORE / ${audioVoices}V SOUND</p>
    <p>PXCL/1 READY</p>
    <p class="prompt" aria-label="command prompt">&gt;<span aria-hidden="true">_</span></p>
    <p id="diagnostic" class="diagnostic" role="status" aria-live="polite"></p>
  </section>
`;

updateIntegerScale();
globalThis.addEventListener('resize', updateIntegerScale);

const diagnosticMode = new URLSearchParams(globalThis.location.search).get('sandbox-test');
if (diagnosticMode !== null) {
  void runSandboxDiagnostic(diagnosticMode);
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
      workUnitsPerFrame: mode === 'runaway' ? 96 : 10_000,
      updateRate: 60,
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
    if (frame.frame !== 0 || frame.drawCommands.length !== 1 || frame.workUnits <= 0) {
      throw new Error('sandbox frame result was incoherent');
    }
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
