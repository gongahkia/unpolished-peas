# Replay

`72.replay.json` stores the validation seed, every `InputFrame`, and the state hash after every frame. The input frame includes independent movement and aim, staff selection, forms, attack, dodge, Echo, restart, and debug toggles.

`go run ./cmd/replaydump 72.replay.json` reconstructs a fresh 1280×720 validation arena and rejects the replay at the first mismatched hash. Follow-camera position, minimap drawing, and visual camera shake are renderer-derived and cannot influence the deterministic random stream.
