# ADR 0003: canonical cartridge container

Status: accepted for format revision 1.

## Decision

Use a small PX-240C-specific sorted container with per-entry SHA-256 and a deterministic
PackBits-style RLE encoding. Store all original PXCL modules, public assets, release JavaScript,
source map, presentation files, and a canonical JSON inventory. Omit timestamps and host metadata.

## Reasoning

A general archive dependency would still require a stricter canonical profile to make one byte
representation authoritative. The implemented container is bounded, straightforward to audit in
Rust and WebAssembly, and small enough for the 256 KiB cartridge ceiling. Compression is modest by
design; reproducibility and decoder simplicity take precedence over maximum compression ratio.

## Consequences

Revision 1 tools must reject alternate RLE packets, unsorted entries, non-canonical paths/JSON,
hash mismatches, trailing data, and decompression beyond limits. Future compression changes require
a new cartridge-format revision rather than silently changing revision-1 output.
