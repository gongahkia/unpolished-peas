# Image assets

On native hosts, `Image.decode` accepts PNG, JPEG, and TGA source bytes and
returns top-left-origin RGBA8 pixels. TGA is limited to true-colour,
uncompressed type-2 files with no colour map and 24- or 32-bit pixels. Limits
apply before allocation: input is at most 32 MiB, each dimension is at most
4096 pixels, and an image contains at most 16,777,216 decoded pixels.

`Image.decode` is currently backed by native stb C code. It is **not** a
freestanding browser asset-decoding API. Browser callback games can render an
`Image` they construct from owned RGBA pixels, but Peas does not yet provide a
portable external PNG/JPEG/TGA loading workflow for game code. Do not present
`AssetStore.loadImage` as a browser-compatible replacement until that path is
implemented and validated.

`Image.decode` returns `UnsupportedImageFormat`, `InvalidImage`,
`ImageInputTooLarge`, `InvalidImageSize`, or `ImageTooLarge` as applicable.
Use game-owned asset bytes and lifetime management; an `Image` owns its pixel
allocation and must be deinitialized after borrowed sprite/atlas users end.
