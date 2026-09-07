import { HARDWARE } from './hardware';

const DATABASE_NAME = 'px240c-studio';
const STORE_NAME = 'records';
const DATABASE_VERSION = 1;
const RECOVERY_LIMIT = 10;

export interface ProjectDocument {
  readonly id: string;
  readonly title: string;
  readonly manifest: string;
  readonly files: Readonly<Record<string, Uint8Array>>;
}

export interface StoredProject extends ProjectDocument {
  readonly revision: number;
}

export interface StudioSettings {
  readonly revision: 1;
  readonly reducedMotion: boolean;
  readonly audioVolume: number;
  readonly editorTabSize: 2;
}

export interface StorageBackend {
  get(key: string): Promise<unknown>;
  set(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<void>;
  keys(prefix: string): Promise<readonly string[]>;
}

/** Browser storage adapter. Cartridge workers never receive this object or an IndexedDB handle. */
export class IndexedDbStorage implements StorageBackend {
  private readonly database: Promise<IDBDatabase>;

  public constructor(name = DATABASE_NAME) {
    this.database = openDatabase(name);
  }

  public async get(key: string): Promise<unknown> {
    const database = await this.database;
    const transaction = database.transaction(STORE_NAME, 'readonly');
    return requestResult(transaction.objectStore(STORE_NAME).get(key));
  }

  public async set(key: string, value: unknown): Promise<void> {
    const database = await this.database;
    const transaction = database.transaction(STORE_NAME, 'readwrite');
    transaction.objectStore(STORE_NAME).put(structuredClone(value), key);
    await transactionDone(transaction);
  }

  public async delete(key: string): Promise<void> {
    const database = await this.database;
    const transaction = database.transaction(STORE_NAME, 'readwrite');
    transaction.objectStore(STORE_NAME).delete(key);
    await transactionDone(transaction);
  }

  public async keys(prefix: string): Promise<readonly string[]> {
    const database = await this.database;
    const transaction = database.transaction(STORE_NAME, 'readonly');
    const keys = await requestResult(transaction.objectStore(STORE_NAME).getAllKeys());
    return keys
      .filter((key): key is string => typeof key === 'string' && key.startsWith(prefix))
      .sort();
  }
}

/** Deterministic in-memory backend for tests and non-persistent embedding. */
export class MemoryStorage implements StorageBackend {
  private readonly records = new Map<string, unknown>();

  public async get(key: string): Promise<unknown> {
    return structuredClone(this.records.get(key));
  }

  public async set(key: string, value: unknown): Promise<void> {
    this.records.set(key, structuredClone(value));
  }

  public async delete(key: string): Promise<void> {
    this.records.delete(key);
  }

  public async keys(prefix: string): Promise<readonly string[]> {
    return [...this.records.keys()].filter((key) => key.startsWith(prefix)).sort();
  }
}

/** Project/settings repository with bounded pre-save recovery history. */
export class StudioRepository {
  private readonly storage: StorageBackend;

  public constructor(storage: StorageBackend = new IndexedDbStorage()) {
    this.storage = storage;
  }

  public async saveProject(project: ProjectDocument): Promise<StoredProject> {
    validateProject(project);
    const key = projectKey(project.id);
    const previous = await this.storage.get(key);
    const previousProject = isStoredProject(previous) ? previous : undefined;
    if (previousProject !== undefined) {
      await this.storage.set(recoveryKey(project.id, previousProject.revision), previousProject);
      await this.pruneRecovery(project.id);
    }
    const stored: StoredProject = {
      ...structuredClone(project),
      revision: (previousProject?.revision ?? 0) + 1,
    };
    await this.storage.set(key, stored);
    return structuredClone(stored);
  }

  public async loadProject(id: string): Promise<StoredProject | undefined> {
    validateId(id);
    const value = await this.storage.get(projectKey(id));
    return isStoredProject(value) ? structuredClone(value) : undefined;
  }

  public async listProjects(): Promise<readonly StoredProject[]> {
    const projects: StoredProject[] = [];
    for (const key of await this.storage.keys('project/')) {
      const value = await this.storage.get(key);
      if (isStoredProject(value)) {
        projects.push(structuredClone(value));
      }
    }
    return projects.sort((left, right) => left.id.localeCompare(right.id));
  }

  public async recoverySnapshots(id: string): Promise<readonly StoredProject[]> {
    validateId(id);
    const snapshots: StoredProject[] = [];
    for (const key of await this.storage.keys(recoveryPrefix(id))) {
      const value = await this.storage.get(key);
      if (isStoredProject(value)) {
        snapshots.push(structuredClone(value));
      }
    }
    return snapshots.sort((left, right) => right.revision - left.revision);
  }

  public async deleteProject(id: string): Promise<void> {
    validateId(id);
    await this.storage.delete(projectKey(id));
    for (const key of await this.storage.keys(recoveryPrefix(id))) {
      await this.storage.delete(key);
    }
  }

  public async settings(): Promise<StudioSettings> {
    const value = await this.storage.get('settings/main');
    return isStudioSettings(value)
      ? structuredClone(value)
      : { revision: 1, reducedMotion: false, audioVolume: 0.8, editorTabSize: 2 };
  }

  public async saveSettings(settings: StudioSettings): Promise<void> {
    if (!isStudioSettings(settings)) {
      throw new TypeError('invalid PX-240C studio settings');
    }
    await this.storage.set('settings/main', settings);
  }

  public cartridgeSave(id: string): CartridgeSaveAccess {
    validateId(id);
    return new CartridgeSaveAccess(this.storage, id);
  }

  private async pruneRecovery(id: string): Promise<void> {
    const keys = await this.storage.keys(recoveryPrefix(id));
    for (const key of keys.slice(0, Math.max(0, keys.length - RECOVERY_LIMIT))) {
      await this.storage.delete(key);
    }
  }
}

/** Capability-scoped save block. Its cartridge id cannot be changed after construction. */
export class CartridgeSaveAccess {
  private readonly storage: StorageBackend;
  readonly #id: string;

  public constructor(storage: StorageBackend, id: string) {
    validateId(id);
    this.storage = storage;
    this.#id = id;
  }

  public async read(): Promise<Uint8Array> {
    const value = await this.storage.get(saveKey(this.#id));
    return value instanceof Uint8Array ? value.slice() : new Uint8Array();
  }

  public async write(value: Uint8Array): Promise<void> {
    if (value.byteLength > HARDWARE.saveCapacityBytes) {
      throw new RangeError('cartridge save exceeds the 8 KiB capacity');
    }
    await this.storage.set(saveKey(this.#id), value.slice());
  }
}

function validateProject(project: ProjectDocument): void {
  validateId(project.id);
  if (project.title.length === 0 || project.title.length > 64 || project.manifest.length === 0) {
    throw new TypeError('invalid PX-240C project title or manifest');
  }
  const entries = Object.entries(project.files);
  if (entries.length === 0 || entries.length > 4096) {
    throw new RangeError('project file count is outside studio limits');
  }
  for (const [path, contents] of entries) {
    if (!validPath(path) || !(contents instanceof Uint8Array)) {
      throw new TypeError(`invalid project file '${path}'`);
    }
  }
}

function isStoredProject(value: unknown): value is StoredProject {
  if (
    !isRecord(value) ||
    typeof value.revision !== 'number' ||
    !Number.isSafeInteger(value.revision) ||
    value.revision < 1
  ) {
    return false;
  }
  try {
    validateProject(value as unknown as ProjectDocument);
    return true;
  } catch {
    return false;
  }
}

function isStudioSettings(value: unknown): value is StudioSettings {
  return (
    isRecord(value) &&
    value.revision === 1 &&
    typeof value.reducedMotion === 'boolean' &&
    typeof value.audioVolume === 'number' &&
    Number.isFinite(value.audioVolume) &&
    value.audioVolume >= 0 &&
    value.audioVolume <= 1 &&
    value.editorTabSize === 2
  );
}

function validateId(id: string): void {
  if (!/^[a-z0-9][a-z0-9.-]{2,63}$/.test(id)) {
    throw new TypeError('invalid cartridge id');
  }
}

function validPath(path: string): boolean {
  return (
    path.length > 0 &&
    path.length <= 1024 &&
    !path.startsWith('/') &&
    !path.includes('\\') &&
    path
      .split('/')
      .every(
        (part) =>
          part.length > 0 && part !== '.' && part !== '..' && /^[A-Za-z0-9._-]+$/.test(part),
      )
  );
}

function projectKey(id: string): string {
  return `project/${id}`;
}

function recoveryPrefix(id: string): string {
  return `recovery/${id}/`;
}

function recoveryKey(id: string, revision: number): string {
  return `${recoveryPrefix(id)}${String(revision).padStart(12, '0')}`;
}

function saveKey(id: string): string {
  return `save/${id}`;
}

function openDatabase(name: string): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(name, DATABASE_VERSION);
    request.addEventListener('upgradeneeded', () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(STORE_NAME)) {
        database.createObjectStore(STORE_NAME);
      }
    });
    request.addEventListener('success', () => resolve(request.result));
    request.addEventListener('error', () => reject(request.error ?? new Error('IndexedDB failed')));
    request.addEventListener('blocked', () => reject(new Error('IndexedDB upgrade is blocked')));
  });
}

function requestResult<Value>(request: IDBRequest<Value>): Promise<Value> {
  return new Promise((resolve, reject) => {
    request.addEventListener('success', () => resolve(request.result));
    request.addEventListener('error', () => reject(request.error ?? new Error('IndexedDB failed')));
  });
}

function transactionDone(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.addEventListener('complete', () => resolve());
    transaction.addEventListener('abort', () =>
      reject(transaction.error ?? new Error('IndexedDB transaction aborted')),
    );
    transaction.addEventListener('error', () =>
      reject(transaction.error ?? new Error('IndexedDB transaction failed')),
    );
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
