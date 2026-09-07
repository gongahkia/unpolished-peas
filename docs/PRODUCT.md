# Product principles

PX-240C Color Development Unit is a small, complete game-making machine. It is presented as a
technically ambitious colour handheld released in 1999 that found a devoted niche but not a large
market. The fiction appears in boot ROM language, restrained industrial surfaces, cartridge labels,
and revision markings; it never takes priority over readable tools or predictable behavior.

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
