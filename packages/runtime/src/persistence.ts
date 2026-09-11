import { HARDWARE } from './hardware';
import { defaultControllerProfile, isControllerProfile, type ControllerProfile } from './input';

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
  readonly storageRevision: 1;
  readonly revision: number;
}

export interface StoredSave {
  readonly revision: 1;
  readonly schemaVersion: number;
  readonly bytes: Uint8Array;
  readonly checksum: string;
}

export interface StudioSettings {
  readonly revision: 2;
  readonly reducedMotion: boolean;
  readonly mutedStartup: boolean;
  readonly highContrast: boolean;
  readonly largeHelp: boolean;
  readonly audioVolume: number;
  readonly editorTabSize: 2;
  readonly controllerProfile: ControllerProfile;
}

export type ShelfOrigin = 'bundled' | 'created' | 'imported' | 'fragment' | 'duplicate';

export interface ShelfState {
  readonly revision: 1;
  readonly origin: ShelfOrigin;
  readonly favorite: boolean;
  readonly lastPlayed: number | null;
}

export interface RemovedProject {
  readonly revision: 1;
  readonly removedAt: number;
  readonly project: StoredProject;
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

  public get(key: string): Promise<unknown> {
    return Promise.resolve(structuredClone(this.records.get(key)));
  }

  public set(key: string, value: unknown): Promise<void> {
    this.records.set(key, structuredClone(value));
    return Promise.resolve();
  }

  public delete(key: string): Promise<void> {
    this.records.delete(key);
    return Promise.resolve();
  }

  public keys(prefix: string): Promise<readonly string[]> {
    return Promise.resolve([...this.records.keys()].filter((key) => key.startsWith(prefix)).sort());
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
    const previousProject = readStoredProject(previous);
    if (previousProject !== undefined) {
      await this.storage.set(recoveryKey(project.id, previousProject.revision), previousProject);
      await this.pruneRecovery(project.id);
    }
    const stored: StoredProject = {
      ...structuredClone(project),
      storageRevision: 1,
      revision: (previousProject?.revision ?? 0) + 1,
    };
    await this.storage.set(key, stored);
    return structuredClone(stored);
  }

  public async loadProject(id: string): Promise<StoredProject | undefined> {
    validateId(id);
    const value = await this.storage.get(projectKey(id));
    const project = readStoredProject(value);
    if (project === undefined) return undefined;
    if (!isStoredProject(value)) {
      const backup = projectMigrationKey(id);
      if ((await this.storage.get(backup)) === undefined) await this.storage.set(backup, value);
      await this.storage.set(projectKey(id), project);
    }
    return structuredClone(project);
  }

  public async listProjects(): Promise<readonly StoredProject[]> {
    const projects: StoredProject[] = [];
    for (const key of await this.storage.keys('project/')) {
      const id = key.slice('project/'.length);
      const value = await this.loadProject(id);
      if (value !== undefined) projects.push(value);
    }
    return projects.sort((left, right) => left.id.localeCompare(right.id));
  }

  public async recoverySnapshots(id: string): Promise<readonly StoredProject[]> {
    validateId(id);
    const snapshots: StoredProject[] = [];
    for (const key of await this.storage.keys(recoveryPrefix(id))) {
      const value = await this.storage.get(key);
      const project = readStoredProject(value);
      if (project !== undefined) snapshots.push(project);
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
    if (isStudioSettings(value)) return structuredClone(value);
    const defaults = defaultStudioSettings();
    if (isLegacySettings(value)) {
      if ((await this.storage.get('migration/settings/alpha')) === undefined)
        await this.storage.set('migration/settings/alpha', value);
      const migrated = {
        ...defaults,
        reducedMotion: value.reducedMotion,
        audioVolume: value.audioVolume,
      };
      await this.storage.set('settings/main', migrated);
      return migrated;
    }
    return defaults;
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

  public async shelfState(id: string): Promise<ShelfState> {
    validateId(id);
    const value = await this.storage.get(shelfKey(id));
    return isShelfState(value)
      ? structuredClone(value)
      : { revision: 1, origin: 'created', favorite: false, lastPlayed: null };
  }

  public async saveShelfState(id: string, state: ShelfState): Promise<void> {
    validateId(id);
    if (!isShelfState(state)) throw new TypeError('invalid cartridge shelf state');
    await this.storage.set(shelfKey(id), state);
  }

  public async setShelfOrigin(id: string, origin: ShelfOrigin): Promise<void> {
    const state = await this.shelfState(id);
    await this.saveShelfState(id, { ...state, origin });
  }

  public async markPlayed(id: string, at = Date.now()): Promise<void> {
    if (!Number.isSafeInteger(at) || at < 0) throw new RangeError('invalid recent timestamp');
    const state = await this.shelfState(id);
    await this.saveShelfState(id, { ...state, lastPlayed: at });
  }

  public async hasCartridgeSave(id: string): Promise<boolean> {
    validateId(id);
    const value = await this.storage.get(saveKey(id));
    if (value instanceof Uint8Array)
      return value.length > 0 && value.length <= HARDWARE.saveCapacityBytes;
    return isStoredSave(value) && value.bytes.some((byte) => byte !== 0);
  }

  /** Moves the only current project copy to local trash; saves and recovery remain isolated. */
  public async removeProjectRecoverably(id: string, at = Date.now()): Promise<void> {
    validateId(id);
    if (!Number.isSafeInteger(at) || at < 0) throw new RangeError('invalid removal timestamp');
    const project = await this.loadProject(id);
    if (project === undefined) throw new Error(`cartridge '${id}' does not exist`);
    const removed: RemovedProject = { revision: 1, removedAt: at, project };
    await this.storage.set(removedKey(id), removed);
    await this.storage.delete(projectKey(id));
  }

  public async removedProjects(): Promise<readonly RemovedProject[]> {
    const removed: RemovedProject[] = [];
    for (const key of await this.storage.keys('removed/')) {
      const value = await this.storage.get(key);
      if (isRemovedProject(value)) removed.push(structuredClone(value));
    }
    return removed.sort(
      (left, right) =>
        right.removedAt - left.removedAt || left.project.id.localeCompare(right.project.id),
    );
  }

  public async restoreRemovedProject(id: string): Promise<StoredProject> {
    validateId(id);
    if ((await this.loadProject(id)) !== undefined)
      throw new Error(`cartridge '${id}' already exists`);
    const value = await this.storage.get(removedKey(id));
    if (!isRemovedProject(value)) throw new Error(`removed cartridge '${id}' was not found`);
    await this.storage.set(projectKey(id), value.project);
    await this.storage.delete(removedKey(id));
    return structuredClone(value.project);
  }

  public async isProjectRemoved(id: string): Promise<boolean> {
    validateId(id);
    return isRemovedProject(await this.storage.get(removedKey(id)));
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
    return (await this.envelope()).bytes.slice();
  }

  public async write(value: Uint8Array, schemaVersion?: number): Promise<void> {
    if (value.byteLength > HARDWARE.saveCapacityBytes) {
      throw new RangeError('cartridge save exceeds the 8 KiB capacity');
    }
    const nextSchema = schemaVersion ?? (await this.envelope()).schemaVersion;
    validateSchemaVersion(nextSchema);
    await this.storage.set(saveKey(this.#id), saveEnvelope(value, nextSchema));
  }

  public async schemaVersion(): Promise<number> {
    return (await this.envelope()).schemaVersion;
  }

  /** Application-controlled, schema-checked migration with no partial write on failure. */
  public async migrate(
    from: number,
    to: number,
    transform: (bytes: Uint8Array) => Uint8Array,
  ): Promise<void> {
    validateSchemaVersion(from);
    validateSchemaVersion(to);
    if (to <= from) throw new RangeError('save migration version must increase');
    const current = await this.envelope();
    if (current.schemaVersion !== from)
      throw new Error(`save schema is ${String(current.schemaVersion)}, expected ${String(from)}`);
    const migrated = transform(current.bytes.slice());
    if (!(migrated instanceof Uint8Array) || migrated.length > HARDWARE.saveCapacityBytes)
      throw new TypeError('save migration produced an invalid image');
    await this.backup(current);
    await this.storage.set(saveKey(this.#id), saveEnvelope(migrated, to));
  }

  public async export(): Promise<Uint8Array> {
    const stored = await this.envelope();
    return new TextEncoder().encode(
      JSON.stringify({
        revision: 1,
        cartridgeId: this.#id,
        schemaVersion: stored.schemaVersion,
        byteLength: stored.bytes.length,
        checksum: stored.checksum,
        bytes: hex(stored.bytes),
      }),
    );
  }

  public async import(serialized: Uint8Array): Promise<void> {
    if (serialized.length === 0 || serialized.length > 2 * HARDWARE.saveCapacityBytes + 1024)
      throw new RangeError('save container byte length is invalid');
    let value: unknown;
    try {
      value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(serialized));
    } catch {
      throw new TypeError('save container is not canonical UTF-8 JSON');
    }
    const imported = decodeSaveExport(value, this.#id);
    const current = await this.envelope();
    await this.backup(current);
    await this.storage.set(saveKey(this.#id), imported);
  }

  public async reset(schemaVersion = 1): Promise<void> {
    validateSchemaVersion(schemaVersion);
    const current = await this.envelope();
    await this.backup(current);
    await this.storage.set(saveKey(this.#id), saveEnvelope(new Uint8Array(), schemaVersion));
  }

  public async clear(): Promise<void> {
    const current = await this.envelope();
    await this.backup(current);
    await this.storage.delete(saveKey(this.#id));
  }

  private async envelope(): Promise<StoredSave> {
    const value = await this.storage.get(saveKey(this.#id));
    if (value === undefined) return saveEnvelope(new Uint8Array(), 1);
    if (value instanceof Uint8Array) {
      if (value.length > HARDWARE.saveCapacityBytes)
        throw new RangeError('stored cartridge save exceeds the 8 KiB capacity');
      const migrated = saveEnvelope(value, 0);
      const backupKey = saveMigrationKey(this.#id);
      if ((await this.storage.get(backupKey)) === undefined)
        await this.storage.set(backupKey, value.slice());
      await this.storage.set(saveKey(this.#id), migrated);
      return migrated;
    }
    if (!isStoredSave(value))
      throw new TypeError('stored cartridge save checksum or schema failed');
    return structuredClone(value);
  }

  private async backup(value: StoredSave): Promise<void> {
    await this.storage.set(saveRecoveryKey(this.#id), structuredClone(value));
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
    value.storageRevision !== 1 ||
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

function readStoredProject(value: unknown): StoredProject | undefined {
  if (isStoredProject(value)) return structuredClone(value);
  if (
    !isRecord(value) ||
    'storageRevision' in value ||
    typeof value.revision !== 'number' ||
    !Number.isSafeInteger(value.revision) ||
    value.revision < 1
  )
    return undefined;
  try {
    validateProject(value as unknown as ProjectDocument);
    return {
      ...(structuredClone(value) as unknown as ProjectDocument),
      storageRevision: 1,
      revision: value.revision,
    };
  } catch {
    return undefined;
  }
}

function saveEnvelope(bytes: Uint8Array, schemaVersion: number): StoredSave {
  return { revision: 1, schemaVersion, bytes: bytes.slice(), checksum: checksum(bytes) };
}

function isStoredSave(value: unknown): value is StoredSave {
  return (
    isRecord(value) &&
    value.revision === 1 &&
    typeof value.schemaVersion === 'number' &&
    Number.isSafeInteger(value.schemaVersion) &&
    value.schemaVersion >= 0 &&
    value.schemaVersion <= 65535 &&
    value.bytes instanceof Uint8Array &&
    value.bytes.length <= HARDWARE.saveCapacityBytes &&
    typeof value.checksum === 'string' &&
    value.checksum === checksum(value.bytes)
  );
}

function decodeSaveExport(value: unknown, id: string): StoredSave {
  if (
    !isRecord(value) ||
    Object.keys(value).length !== 6 ||
    value.revision !== 1 ||
    value.cartridgeId !== id ||
    typeof value.schemaVersion !== 'number' ||
    typeof value.byteLength !== 'number' ||
    typeof value.checksum !== 'string' ||
    typeof value.bytes !== 'string'
  )
    throw new TypeError('save container identity or schema is invalid');
  validateSchemaVersion(value.schemaVersion);
  if (
    !Number.isSafeInteger(value.byteLength) ||
    value.byteLength < 0 ||
    value.byteLength > HARDWARE.saveCapacityBytes
  )
    throw new RangeError('save container byte length is invalid');
  const bytes = unhex(value.bytes, value.byteLength);
  const stored = saveEnvelope(bytes, value.schemaVersion);
  if (stored.checksum !== value.checksum) throw new TypeError('save container checksum failed');
  return stored;
}

function validateSchemaVersion(value: number): void {
  if (!Number.isSafeInteger(value) || value < 0 || value > 65535)
    throw new RangeError('save schema version is invalid');
}

function checksum(bytes: Uint8Array): string {
  let value = 0xffff_ffff;
  for (const byte of bytes) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit += 1) value = (value >>> 1) ^ (value & 1 ? 0xedb8_8320 : 0);
  }
  return ((value ^ 0xffff_ffff) >>> 0).toString(16).padStart(8, '0');
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

function unhex(value: string, length: number): Uint8Array {
  if (value.length !== length * 2 || !/^(?:[0-9a-f]{2})*$/.test(value))
    throw new TypeError('save container bytes are not canonical lowercase hexadecimal');
  const bytes = new Uint8Array(length);
  for (let index = 0; index < length; index += 1)
    bytes[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
  return bytes;
}

function isStudioSettings(value: unknown): value is StudioSettings {
  return (
    isRecord(value) &&
    value.revision === 2 &&
    typeof value.reducedMotion === 'boolean' &&
    typeof value.mutedStartup === 'boolean' &&
    typeof value.highContrast === 'boolean' &&
    typeof value.largeHelp === 'boolean' &&
    typeof value.audioVolume === 'number' &&
    Number.isFinite(value.audioVolume) &&
    value.audioVolume >= 0 &&
    value.audioVolume <= 1 &&
    value.editorTabSize === 2 &&
    isControllerProfile(value.controllerProfile)
  );
}

function isLegacySettings(value: unknown): value is {
  revision: 1;
  reducedMotion: boolean;
  audioVolume: number;
  editorTabSize: 2;
} {
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

function defaultStudioSettings(): StudioSettings {
  return {
    revision: 2,
    reducedMotion: false,
    mutedStartup: true,
    highContrast: false,
    largeHelp: false,
    audioVolume: 0.8,
    editorTabSize: 2,
    controllerProfile: defaultControllerProfile(),
  };
}

function isShelfState(value: unknown): value is ShelfState {
  return (
    isRecord(value) &&
    value.revision === 1 &&
    ['bundled', 'created', 'imported', 'fragment', 'duplicate'].includes(String(value.origin)) &&
    typeof value.favorite === 'boolean' &&
    (value.lastPlayed === null ||
      (typeof value.lastPlayed === 'number' &&
        Number.isSafeInteger(value.lastPlayed) &&
        value.lastPlayed >= 0))
  );
}

function isRemovedProject(value: unknown): value is RemovedProject {
  return (
    isRecord(value) &&
    value.revision === 1 &&
    typeof value.removedAt === 'number' &&
    Number.isSafeInteger(value.removedAt) &&
    value.removedAt >= 0 &&
    isStoredProject(value.project)
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

function projectMigrationKey(id: string): string {
  return `migration/project/${id}/alpha`;
}

function saveMigrationKey(id: string): string {
  return `migration/save/${id}/alpha`;
}

function saveRecoveryKey(id: string): string {
  return `recovery-save/${id}/latest`;
}

function shelfKey(id: string): string {
  return `shelf/${id}`;
}

function removedKey(id: string): string {
  return `removed/${id}`;
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
    request.addEventListener('success', () => {
      resolve(request.result);
    });
    request.addEventListener('error', () => {
      reject(request.error ?? new Error('IndexedDB failed'));
    });
    request.addEventListener('blocked', () => {
      reject(new Error('IndexedDB upgrade is blocked'));
    });
  });
}

function requestResult<Value>(request: IDBRequest<Value>): Promise<Value> {
  return new Promise((resolve, reject) => {
    request.addEventListener('success', () => {
      resolve(request.result);
    });
    request.addEventListener('error', () => {
      reject(request.error ?? new Error('IndexedDB failed'));
    });
  });
}

function transactionDone(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.addEventListener('complete', () => {
      resolve();
    });
    transaction.addEventListener('abort', () => {
      reject(transaction.error ?? new Error('IndexedDB transaction aborted'));
    });
    transaction.addEventListener('error', () => {
      reject(transaction.error ?? new Error('IndexedDB transaction failed'));
    });
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
