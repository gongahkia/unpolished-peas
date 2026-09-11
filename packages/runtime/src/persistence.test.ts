import { describe, expect, it } from 'vitest';

import { HARDWARE } from './hardware';
import { MemoryStorage, StudioRepository, type ProjectDocument } from './persistence';

function project(source: string): ProjectDocument {
  return {
    id: 'test.project',
    title: 'TEST PROJECT',
    manifest: 'format = 1',
    files: { 'src/main.pxl': new TextEncoder().encode(source) },
  };
}

describe('browser project and save persistence', () => {
  it('autosaves projects with bounded pre-save recovery snapshots', async () => {
    const repository = new StudioRepository(new MemoryStorage());
    for (let revision = 0; revision < 12; revision += 1) {
      const stored = await repository.saveProject(
        project(`state score: Int = ${String(revision)}`),
      );
      expect(stored.revision).toBe(revision + 1);
    }
    const loaded = await repository.loadProject('test.project');
    expect(new TextDecoder().decode(loaded?.files['src/main.pxl'])).toContain('11');
    const recovery = await repository.recoverySnapshots('test.project');
    expect(recovery).toHaveLength(10);
    expect(recovery[0]?.revision).toBe(11);
    expect(recovery.at(-1)?.revision).toBe(2);
  });

  it('lists/deletes projects and validates settings', async () => {
    const repository = new StudioRepository(new MemoryStorage());
    await repository.saveProject(project('on draw:\n  clear(0)\n'));
    expect((await repository.listProjects()).map((value) => value.id)).toEqual(['test.project']);
    await repository.saveSettings({
      ...(await repository.settings()),
      revision: 2,
      reducedMotion: true,
      audioVolume: 0.5,
    });
    expect(await repository.settings()).toMatchObject({ reducedMotion: true, audioVolume: 0.5 });
    await repository.deleteProject('test.project');
    expect(await repository.listProjects()).toEqual([]);
    expect(await repository.recoverySnapshots('test.project')).toEqual([]);
  });

  it('migrates alpha settings and preserves accessibility and controller profiles', async () => {
    const storage = new MemoryStorage();
    const legacy = { revision: 1, reducedMotion: true, audioVolume: 0.25, editorTabSize: 2 };
    await storage.set('settings/main', legacy);
    const repository = new StudioRepository(storage);
    const migrated = await repository.settings();
    expect(migrated).toMatchObject({
      revision: 2,
      reducedMotion: true,
      mutedStartup: true,
      highContrast: false,
      largeHelp: false,
      audioVolume: 0.25,
      controllerProfile: { revision: 1, gamepads: [0, 1, 2, 3] },
    });
    expect(await storage.get('migration/settings/alpha')).toEqual(legacy);
    await repository.saveSettings({ ...migrated, highContrast: true, largeHelp: true });
    expect(await repository.settings()).toMatchObject({ highContrast: true, largeHelp: true });
  });

  it('isolates save blocks by immutable cartridge id and enforces 8 KiB', async () => {
    const storage = new MemoryStorage();
    const repository = new StudioRepository(storage);
    const first = repository.cartridgeSave('first.game');
    const second = repository.cartridgeSave('second.game');
    await first.write(Uint8Array.of(1, 2, 3));
    await second.write(Uint8Array.of(9));
    expect(await first.read()).toEqual(Uint8Array.of(1, 2, 3));
    expect(await second.read()).toEqual(Uint8Array.of(9));
    await expect(first.write(new Uint8Array(HARDWARE.saveCapacityBytes + 1))).rejects.toThrow(
      /8 KiB/,
    );
  });

  it('migrates raw alpha projects and saves without replacing the only old copy', async () => {
    const storage = new MemoryStorage();
    const legacy = { ...project('on draw:\n  clear(0)\n'), revision: 3 };
    await storage.set('project/test.project', legacy);
    await storage.set('save/test.project', Uint8Array.of(1, 2, 3));
    const repository = new StudioRepository(storage);
    expect(await repository.loadProject('test.project')).toMatchObject({
      storageRevision: 1,
      revision: 3,
    });
    expect(await storage.get('migration/project/test.project/alpha')).toEqual(legacy);
    const save = repository.cartridgeSave('test.project');
    expect(await save.read()).toEqual(Uint8Array.of(1, 2, 3));
    expect(await save.schemaVersion()).toBe(0);
    expect(await storage.get('migration/save/test.project/alpha')).toEqual(Uint8Array.of(1, 2, 3));

    await save.migrate(0, 2, (bytes) => Uint8Array.from([...bytes, 4]));
    expect(await save.schemaVersion()).toBe(2);
    expect(await save.read()).toEqual(Uint8Array.of(1, 2, 3, 4));
    const exported = await save.export();
    await save.reset(2);
    expect(await save.read()).toEqual(new Uint8Array());
    await save.import(exported);
    expect(await save.read()).toEqual(Uint8Array.of(1, 2, 3, 4));

    const corrupt = new TextEncoder().encode(
      new TextDecoder().decode(exported).replace('01020304', '01020305'),
    );
    await expect(save.import(corrupt)).rejects.toThrow(/checksum/);
    expect(await save.read()).toEqual(Uint8Array.of(1, 2, 3, 4));
  });

  it('rejects cross-cartridge, truncated, oversized, and noncanonical save containers', async () => {
    const repository = new StudioRepository(new MemoryStorage());
    const source = repository.cartridgeSave('first.game');
    const target = repository.cartridgeSave('second.game');
    await source.write(Uint8Array.of(7), 4);
    const exported = await source.export();
    await expect(target.import(exported)).rejects.toThrow(/identity/);
    await expect(source.import(exported.slice(0, -1))).rejects.toThrow();
    await expect(
      source.import(new Uint8Array(HARDWARE.saveCapacityBytes * 2 + 1025)),
    ).rejects.toThrow(/length/);
    const uppercase = new TextEncoder().encode(
      new TextDecoder().decode(exported).replace('07', '0A'),
    );
    await expect(source.import(uppercase)).rejects.toThrow(/lowercase|checksum/);
    expect(await source.read()).toEqual(Uint8Array.of(7));
  });

  it('tracks shelf origin, favorites, recents, save presence, and recoverable removal', async () => {
    const repository = new StudioRepository(new MemoryStorage());
    const stored = await repository.saveProject(project('on draw:\n  clear(0)\n'));
    await repository.setShelfOrigin(stored.id, 'imported');
    await repository.saveShelfState(stored.id, {
      ...(await repository.shelfState(stored.id)),
      favorite: true,
    });
    await repository.markPlayed(stored.id, 240);
    await repository.cartridgeSave(stored.id).write(Uint8Array.of(1));
    expect(await repository.shelfState(stored.id)).toEqual({
      revision: 1,
      origin: 'imported',
      favorite: true,
      lastPlayed: 240,
    });
    expect(await repository.hasCartridgeSave(stored.id)).toBe(true);

    await repository.removeProjectRecoverably(stored.id, 241);
    expect(await repository.loadProject(stored.id)).toBeUndefined();
    expect((await repository.removedProjects())[0]).toMatchObject({
      removedAt: 241,
      project: { id: stored.id, revision: stored.revision },
    });
    expect(await repository.hasCartridgeSave(stored.id)).toBe(true);
    expect((await repository.restoreRemovedProject(stored.id)).revision).toBe(stored.revision);
    expect((await repository.loadProject(stored.id))?.id).toBe(stored.id);
  });
});
