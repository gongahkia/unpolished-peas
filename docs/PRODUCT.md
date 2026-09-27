# Product principles

PX-240C Color Development Unit is a small, complete game-making machine. It is presented as a
technically ambitious colour handheld released in 1999 that found a devoted niche but not a large
market. The fiction appears in boot ROM language, restrained industrial surfaces, cartridge labels,
and revision markings; it never takes priority over readable tools or predictable behavior.

## V1 release-candidate contract

This document, [LIMITS.md](LIMITS.md), and [V1_RELEASE_EVIDENCE.md](V1_RELEASE_EVIDENCE.md) are the
current V1 scope, constraints, and verification record. [PROGRESS.md](PROGRESS.md) and
[COMPETITIVE_GAP_AUDIT.md](COMPETITIVE_GAP_AUDIT.md) are historical implementation records, not
additional open scope.

PXCL/1 and cartridge format revision 1 are frozen. The private workspace remains
`0.1.0-alpha.1` until a deliberately versioned public release; the compiler version is embedded in
canonical cartridge metadata, so changing it must rebuild and re-record release artifacts. The three
preserved alpha game projects retain their `1.0.0-alpha.1` manifests and frozen compatibility hashes.
V1-added cartridges use their authored `1.0.0` game versions. This distinction is intentional and
does not imply unfinished V1 product scope.

## Audience

The primary audience is experienced game developers, size coders, demo-scene authors, language-tool
enthusiasts, and curious programmers who enjoy understanding the whole machine. PXCL/1 remains
compact enough to teach, but the alpha favors explicit types, inspectable lowering, deterministic
state, and useful debugging over hiding the system.

## Principles

- The 240x144 display is the product surface. Shell, editors, debugger, and cartridges share it.
- A cartridge is understandable. Original PXCL and source-visible assets survive packing and export.
- Constraints form one coherent machine. Graphics, audio, input, saves, work, and capacity meters
  agree across compiler, Studio, CLI, and standalone player.
- Determinism is observable. Time follows frames, RNG is owned by the console, and rewind reports
  divergence instead of silently inventing history.
- Local ownership comes first. Projects, recovery revisions, and saves stay on the user's device;
  there is no account, backend, gallery, or network API.
- Fiction is seasoning. No fabricated manufacturer, CPU clock, online service, or compatibility
  claim is used to make the project seem larger than it is.

## Position

PX-240C belongs to the broader tradition of constrained fantasy consoles while choosing a distinct
center: a statically typed cartridge language, compiler explorer, source debugger, deterministic
time travel, four-port handheld profile, indexed raster display list, and source-preserving
distribution. It does not import or emulate cartridges from another console. Existing fantasy
consoles remain their own creative ecosystems; PX-240C is an original alternative with different
tradeoffs rather than a replacement.
