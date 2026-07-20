# Stable image assets

The v0.1 image subset accepts PNG, JPEG, and TGA source files and decodes them to top-left-origin RGBA8 pixels before sprite upload. TGA is limited to true-colour, uncompressed type-2 files with no colour map and 24- or 32-bit pixels. PNG and JPEG use the host image decoder; unsupported source formats are rejected before decode.

Limits apply before allocation on every host: input is at most 32 MiB, each dimension is at most 4096 pixels, and an image contains at most 16,777,216 decoded pixels. `Image.decode` returns `UnsupportedImageFormat`, `InvalidImage`, `ImageInputTooLarge`, `InvalidImageSize`, or `ImageTooLarge` as applicable; `AssetStore.loadImage` preserves those errors. Browser package loading reports the stable `asset_load_failed:image_v1` diagnostic for a missing, malformed, unsupported, or over-limit source.

The package tests decode and upload PNG, JPEG, and TGA fixtures through forced WebGL 2 and WebGPU, then read an opaque source pixel back after sprite rendering. The same fixture contract is exercised by native `Image.decode`; nearest sprite upload preserves the decoded RGBA values.
