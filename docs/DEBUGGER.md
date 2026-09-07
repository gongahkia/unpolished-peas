# PX-240C debugger and profiler

Run `debug` in the Studio monitor with a cartridge loaded. The Studio compiles the project in debug
mode from the same typed IR used for release output, starts a fresh capability-limited worker, and
initially pauses before frame 0. Debug runs do not write back to the durable cartridge save block;
they begin from a copy of its current values so rewind cannot silently replace player progress.

## Controls

- `RUN`/`PAUSE` controls frame scheduling. `FRAME` executes one complete display frame.
- `BRK` adds a source-line breakpoint. Supplying a condition evaluates it at matching probe events;
  adding the same line with an empty condition removes it.
- `IN`, `OVER`, and `OUT` navigate real source-probe events captured for the most recently executed
  frame. At the end of the trace they execute one more frame and select its first event.
- `-1F`, the timeline slider, and `RST` restore/replay to an earlier next-frame cursor. Resuming from
  an earlier cursor creates a new recorded branch.
- `ADD` retains up to four watch expressions. `SND` enables audible debug playback after the browser
  user gesture. Shift+Escape stops the worker and returns to the monitor.

The watch/condition evaluator is not JavaScript and does not use dynamic code execution. It supports
PXCL-like literals, names, record fields, collection indices, parentheses, `not`, arithmetic,
comparisons, `and`, and `or`. Calls, assignments, and prototype fields are rejected. Conditions must
produce `Bool`.

## Inspection and profiling

Debug generation inserts source-span probes before statements and retains stable symbol IDs. A
probe captures current routine/task locals and the call stack at that point. The STATE, TASK, and
SOURCE pages resolve IDs back to PXCL names and show the linked debug source. A trace is bounded to
4,096 events per frame; the source page reports truncation explicitly.

PROFILE aggregates the synthetic work units already charged by function entries, loop back-edges,
task transitions, allocation, and console calls. MEMORY reports indexed framebuffer use, distinct
colours, source-visible assets, display raster rows, shared visual bytes, and packed cartridge bytes.
AUDIO shows each deterministic synthesizer voice and tracker cursor. These are console-model work
units and capacity meters, not host CPU measurements.

## Snapshots, replay, and divergence

The journal records every four-port controller/pointer input and a deterministic fingerprint of the
worker response, draw/audio commands, save writes, debug trace, and state/task inspection. Composite
snapshots contain worker state (frame, RNG, input history, globals, task program counters/locals, and
debug-local save copy), persistent/resolved indexed framebuffer state, and all synthesizer/tracker
state. A snapshot is taken before frame 0 and every 30 frames. The current alpha retains roughly
3,600 frames plus the snapshot interval needed to anchor replay.

Rewind restores the nearest retained composite snapshot and replays recorded input without audible
output or persistent-save writes. Every replayed frame is fingerprinted; the Studio stops and names
the first divergent frame instead of displaying silently incorrect history.

## Intentional alpha limitations

Execution breakpoints pause at the end of the frame containing a matching event. Trace stepping
navigates immutable event snapshots while execution remains paused; it does not suspend JavaScript
mid-statement or roll back part of a callback. This gives deterministic and inspectable semantics
without replaying side effects from a partially executed synchronous callback.

Revision-1 project linking produces one deterministic linked debug source, so locations in imported
projects refer to that source rather than individual original modules. `on start` executes while the
worker loads and is represented in the initial state snapshot, but its probe trace is not retained.
The profiler is cumulative for the current debug session rather than rewound with the frame cursor.
