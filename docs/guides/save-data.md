# Save data

`up.core.SaveStore` persists small, game-owned byte blobs. It is intended for
settings, progression, unlocks, and high scores. It is not an arbitrary
filesystem API, database, cloud service, serializer, or a home for large
replay archives.

The game owns the bytes and their versioning; Peas only chooses a safe
per-application location and transports those bytes. A game can use JSON or a
small explicit binary format, but it must not persist raw Zig struct memory.

## Use it

Runtime hosts provide a store through `GameContext.save_data`. A game that
requires persistence can use `requireSaveData`; a game for which saving is
optional can check the nullable field and continue after a recoverable error.

```zig
pub fn load(self: *Game, ctx: *up.core.GameContext) !void {
    const saves = try ctx.requireSaveData();
    var bytes: [4]u8 = undefined;
    const stored = saves.read("best-score", &bytes) catch |err| switch (err) {
        error.NotFound => return,
        else => return err,
    };
    if (stored.len == bytes.len) self.best_score = std.mem.readInt(u32, &bytes, .little);
}

pub fn save(self: Game, ctx: *up.core.GameContext) !void {
    const saves = try ctx.requireSaveData();
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, self.best_score, .little);
    try saves.write("best-score", &bytes);
}
```

`read` fills caller-owned storage. For a variable-size blob, use
`readAlloc(allocator, key, max_bytes)` and free the returned slice with that
same allocator. The maximum is a caller-selected corruption and allocation
guard. `write`, `delete`, and `exists` complete the v1 API.

Keys are names, not paths: they are 1–64 ASCII bytes from letters, digits,
`.`, `_`, and `-`, but may not contain `..`, `/`, `\\`, `:`, or NUL. Invalid
keys fail with `error.InvalidKey`; Peas never rewrites them. A game may express
its own slots with keys such as `settings`, `slot-1`, and `progress.v2`.

## Application identity and native storage

The SDL desktop host takes its stable namespace from `sdl.Config.organization`
and `sdl.Config.application`, not from the window title. SDL resolves a
per-user preference directory, and Peas stores each key beneath its `saves/`
child:

- Linux follows SDL's XDG path: `$XDG_DATA_HOME/<organization>/<application>/`
  or `$HOME/.local/share/<organization>/<application>/` when it is unset.
- macOS uses `~/Library/Application Support/<organization>/<application>/`.
- Windows uses the user roaming AppData directory with the same organization
  and application components.

The save directory is created only when the desktop host starts. Native writes
write and `sync` a temporary file in that directory, then perform a
same-directory replacement rename. This protects the previous file from a
normal failed write, but it is not a journal and does not claim power-loss
durability on every filesystem. Permission and I/O failures remain explicit
errors; they are never reported as a missing value.

## Browser storage

A callback game built for the browser can declare a stable portable ID:

```zig
pub const storage_id = "example.seed-sprint";
```

The browser runtime maps the same `SaveStore` calls to synchronous
`localStorage`, using the host prefix, `storage_id`, and game key as an internal
namespaced key. Values are stored as a `UPST1:`-prefixed Base64 encoding, so
all byte values—including an empty blob and NUL—round-trip unchanged. The
browser host distinguishes missing, malformed, unavailable, and rejected
storage.

Browser policy, private browsing, security settings, and quota can make
`localStorage` unavailable or reject a write. Treat such errors as recoverable.
The current host limits one raw value to 1 MiB before Base64 expansion and is
deliberately for small data. It is not a cross-platform replay archive store; large recordings,
user-generated content, IndexedDB, OPFS, and cloud synchronization remain out
of scope.

## Deterministic tests

Save data is environmental initial state. A reproducible run requires the
same seed, replay, initial store contents, and deterministic game code. Save
contents are not inserted into UPR replay files.

`HeadlessGameRunner` creates a known-empty `InMemorySaveStore` by default, so
it never reads or writes a developer's desktop save directory. Tests that need
saved state create and preload an `up.testSupport.InMemorySaveStore`, then use
`initWithSaveData` or `initSeededWithSaveData` to inject its capability.

Saving is synchronous and should happen at meaningful transitions—such as a
new high score or an explicit checkpoint—not every frame or fixed tick. Seed
Sprint uses a four-byte little-endian `best-score` payload as a minimal example;
Peas does not inspect or migrate it.
