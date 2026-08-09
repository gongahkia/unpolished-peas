# Replay

`72.replay.json` stores the validation seed, every `InputFrame`, and the state hash after every frame. The input frame includes independent movement and aim, staff selection, forms, attack, dodge, Echo, restart, and debug toggles.

`go run ./cmd/replaydump 72.replay.json` reconstructs a fresh validation arena and rejects the replay at the first mismatched hash. Visual camera shake is not part of the state and cannot influence the deterministic random stream.
