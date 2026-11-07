# Local chess example review — November 7, 2026

Full interface review of the new local chess example, using the existing
Canvas primitives and authored fonts. No second UI styling system or image
library was introduced. Evidence includes source inspection, real Chromium
interaction checks, and initial, mate, promotion and keyboard-frame screenshots.

| Category | Evidence inspected | Result |
| --- | --- | --- |
| Typography | Source Sans instructions, status text, coordinate labels and screenshots | Clear |
| Surfaces | 48×48 board squares, 184×40 controls, selection/check/last-move feedback, confirmations | Clear |
| Animations | Static move/selection feedback; no custom animation | Clear; slow-motion replay not applicable |
| Icons | Six Canvas piece silhouettes, contrasting outlines and piece identity after underpromotion | Clear |
| Performance | Prepared instructions, bounded undo/repetition storage, native allocation checks | Clear |

No actionable interface-polish findings.

| Location | Candidate | Rejected because |
| --- | --- | --- |
| Board moves | Animate every move | Immediate selection and last-move highlights communicate state without repeated motion. |
| Piece interaction | Add dragging alongside click-to-move | Click-to-move and keyboard controls already cover the primary local-play path; dragging would add pointer states to verify. |

Verified commands:

```sh
zig build test-chess test-browser-chess -Doptimize=ReleaseFast -Dbrowser-optimize=ReleaseFast -j2 --summary all
zig build run-chess -Doptimize=ReleaseFast -j2 --summary all -- --frames 8
```

Native tests passed six cases in Debug and six in ReleaseFast, including the
six reference move trees totaling 500,117 leaf positions. The standalone Wasm
probe passed the same rule checks. Real Chromium 157/WebGL 2 passed a complete
game and exact initial/mate native pixel comparisons; both castlings, en
passant, underpromotion, draw claim, keyboard movement, undo, flip, restart
and resignation also passed. The native Cocoa/SDL GPU/Metal window smoke passed.

The undo ring allocates during initialization and frees on shutdown, keeping
large state out of static Wasm memory. Resource-leak tests and drawing-allocation
checks passed. The ordinary browser host needs no memory-import customization.

Verdict: **Approve**. Not verified for this new example: Firefox/Safari
interaction runs, other native operating systems, and assistive-technology
navigation of Canvas contents. The guide documents local play, bounded undo,
draw-rule scope and the absence of online play/AI/clocks/saves.
