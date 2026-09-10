import { RuntimeFault } from './errors';
import type { HostRequest, SandboxConfiguration, WorkerResponse } from './protocol';
import { isWorkerResponse } from './protocol';
import type { InputFrame } from './input';
import type { MemoryRegionDescriptor } from './bus';

interface PendingRequest {
  readonly resolve: (response: WorkerResponse) => void;
  readonly reject: (reason: Error) => void;
  readonly timer: ReturnType<typeof setTimeout>;
}

/** Host-side lifecycle for one disposable cartridge worker. */
export class SandboxSession {
  private readonly worker: Worker;
  private readonly timeoutMilliseconds: number;
  private readonly pending = new Map<number, PendingRequest>();
  private nextRequestId = 1;
  private disposed = false;

  public constructor(worker: Worker, timeoutMilliseconds = 500) {
    if (!Number.isSafeInteger(timeoutMilliseconds) || timeoutMilliseconds < 10) {
      throw new RangeError('sandbox timeout must be an integer of at least 10 milliseconds');
    }
    this.worker = worker;
    this.timeoutMilliseconds = timeoutMilliseconds;
    this.worker.addEventListener('message', this.handleMessage);
    this.worker.addEventListener('error', this.handleWorkerError);
    this.worker.addEventListener('messageerror', this.handleMessageError);
  }

  public async load(javascript: string, configuration: SandboxConfiguration): Promise<void> {
    const moduleUrl = URL.createObjectURL(new Blob([javascript], { type: 'text/javascript' }));
    try {
      const response = await this.request((id) => ({
        id,
        type: 'load',
        moduleUrl,
        configuration,
      }));
      this.expectResponse(response, 'loaded');
    } finally {
      URL.revokeObjectURL(moduleUrl);
    }
  }

  public async frame(input: InputFrame): Promise<Extract<WorkerResponse, { type: 'frame' }>> {
    const response = await this.request((id) => ({ id, type: 'frame', input }));
    this.expectResponse(response, 'frame');
    return response;
  }

  public async snapshot(): Promise<unknown> {
    const response = await this.request((id) => ({ id, type: 'snapshot' }));
    this.expectResponse(response, 'snapshot');
    return response.snapshot;
  }

  public async audit(): Promise<Extract<WorkerResponse, { type: 'audit' }>> {
    const response = await this.request((id) => ({ id, type: 'audit' }));
    this.expectResponse(response, 'audit');
    return response;
  }

  public async restore(snapshot: unknown): Promise<void> {
    const response = await this.request((id) => ({ id, type: 'restore', snapshot }));
    this.expectResponse(response, 'restored');
  }

  public async inspectMemory(
    address: number,
    length: number,
  ): Promise<{
    readonly address: number;
    readonly bytes: Uint8Array;
    readonly regions: readonly MemoryRegionDescriptor[];
  }> {
    const response = await this.request((id) => ({ id, type: 'memory', address, length }));
    this.expectResponse(response, 'memory');
    return response;
  }

  public async editMemory(address: number, bytes: Uint8Array): Promise<void> {
    const response = await this.request((id) => ({ id, type: 'memory-edit', address, bytes }));
    this.expectResponse(response, 'memory-edited');
  }

  public dispose(): void {
    this.shutdown(new Error('sandbox worker was disposed'));
  }

  private readonly handleMessage = (event: MessageEvent<unknown>): void => {
    if (!isWorkerResponse(event.data)) {
      this.disposeWithError(new Error('sandbox worker returned an invalid protocol message'));
      return;
    }
    const pending = this.pending.get(event.data.id);
    if (pending === undefined) {
      return;
    }
    clearTimeout(pending.timer);
    this.pending.delete(event.data.id);
    if (event.data.type === 'error') {
      pending.reject(
        new RuntimeFault(
          event.data.code,
          event.data.message,
          event.data.sourceSpan ?? { start: 0, end: 0 },
        ),
      );
    } else {
      pending.resolve(event.data);
    }
  };

  private readonly handleWorkerError = (event: ErrorEvent): void => {
    this.disposeWithError(new Error(`sandbox worker failed: ${event.message}`));
  };

  private readonly handleMessageError = (): void => {
    this.disposeWithError(new Error('sandbox worker returned data that could not be cloned'));
  };

  private request(create: (id: number) => HostRequest): Promise<WorkerResponse> {
    if (this.disposed) {
      return Promise.reject(new Error('sandbox worker is disposed'));
    }
    const id = this.nextRequestId;
    this.nextRequestId += 1;
    return new Promise<WorkerResponse>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error('sandbox worker exceeded its host response deadline'));
        this.dispose();
      }, this.timeoutMilliseconds);
      this.pending.set(id, { resolve, reject, timer });
      this.worker.postMessage(create(id));
    });
  }

  private expectResponse<Type extends WorkerResponse['type']>(
    response: WorkerResponse,
    expected: Type,
  ): asserts response is Extract<WorkerResponse, { type: Type }> {
    if (response.type !== expected) {
      throw new Error(`sandbox protocol expected '${expected}', received '${response.type}'`);
    }
  }

  private disposeWithError(error: Error): void {
    this.shutdown(error);
  }

  private shutdown(reason: Error): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.worker.removeEventListener('message', this.handleMessage);
    this.worker.removeEventListener('error', this.handleWorkerError);
    this.worker.removeEventListener('messageerror', this.handleMessageError);
    this.worker.terminate();
    this.rejectAll(reason);
  }

  private rejectAll(error: Error): void {
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    this.pending.clear();
  }
}
