# Project asset packages

72 packages a declared project filesystem into a deterministic JSON artifact.
The package format records source paths, standard asset types, dependency paths,
content digests, and whether source bytes are embedded or external. It is an
asset build contract, not a general archive format or marketplace format.

## `72.assets.json`

Place one manifest at a project-relative path, normally `72.assets.json`:

```json
{
  "version": 1,
  "name": "first-game",
  "assets": [
    {
      "path": "art/tiles.png",
      "type": "image",
      "mode": "embed"
    },
    {
      "path": "maps/first.tiles.json",
      "type": "tile-map",
      "mode": "embed",
      "dependencies": ["art/tiles.png"]
    },
    {
      "path": "audio/music.wav",
      "type": "audio",
      "mode": "external"
    }
  ]
}
```

`version` must be `1`; `name` identifies the package; and `assets` is a
non-empty list. Every `path` and dependency is a normalized project-relative
`fs.ValidPath`: no absolute paths, `.` segments, or `..` traversal. Asset paths
and per-asset dependencies must be unique. Dependencies must name another
declared asset and cannot point to the declaring asset.

The currently supported types are `image`, `font`, `audio`, and `tile-map`.
They are validated with the standard loaders documented in
[portable asset loaders](ASSETS.md). A tile map must list its JSON `texture`
path as a dependency, and that dependency must be an `image` asset.

## Embedded and external records

`"mode": "embed"` stores the exact validated source bytes in the generated
artifact. `"mode": "external"` validates the source while building but stores
only its SHA-256 digest, path, type, mode, and dependencies. Runtime or release
distribution tooling must provide external content that matches this digest;
72 does not silently substitute a platform-specific source.

## Build API

```go
manifest, err := assets.LoadProjectManifest(projectFiles, "72.assets.json")
artifact, err := assets.BuildPackage(projectFiles, manifest)
if err != nil {
	return err
}
reader, err := assets.OpenPackage(bytes.NewReader(artifact), projectFiles)
if err != nil {
	return err
}
data, err := reader.ReadAsset("maps/first.tiles.json")
if err != nil {
	return err
}
```

`BuildPackage` validates every declared source file before encoding. It sorts
records and dependency paths before serializing, so equal manifest values and
filesystem content produce byte-identical package artifacts even if the input
asset array order differs. The output is canonical JSON with base64-encoded
embedded bytes; this keeps it inspectable while the release workflow is still
being established.

Missing source files, malformed assets, unsupported types or modes, invalid
paths, duplicate declarations, undeclared dependencies, and mismatched tile
map texture dependencies fail with the affected manifest or asset path in the
error.

`OpenPackage` accepts exactly one JSON value, rejects unknown fields, validates
the package metadata, validates embedded digests immediately, and returns only
copied data. `ReadAsset` resolves external records through the explicit
`fs.FS` passed to `OpenPackage`; it verifies its SHA-256 digest and reruns the
standard type validation before returning bytes. It does not use a working
directory, an implicit filesystem, or a network resolver.

## Command-line packaging

The `72` command writes a package atomically, so an existing output file is
left intact when validation or writing fails:

```sh
go run ./cmd/72 pack -root . -manifest 72.assets.json -out build/game.72.json
```

`-root` defaults to the current directory and `-manifest` defaults to
`72.assets.json`. `-out` is required; its parent directory must already exist.
The command performs the same source validation and canonical serialization as
`BuildPackage`.
