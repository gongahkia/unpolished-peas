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
      revision: 1,
      reducedMotion: true,
      audioVolume: 0.5,
      editorTabSize: 2,
    });
    expect(await repository.settings()).toMatchObject({ reducedMotion: true, audioVolume: 0.5 });
    await repository.deleteProject('test.project');
    expect(await repository.listProjects()).toEqual([]);
    expect(await repository.recoverySnapshots('test.project')).toEqual([]);
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
});
