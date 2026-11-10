# Ashen Causeway — framework friction

Started 2026-11-10 at engine revision 1d202e9f. This is the canonical report.
No engine defect has been demonstrated yet. The game is in development; this
report does not certify complete gameplay or platform validation.

## Observations

- Fixed-tick, game-owned combat is ordinary Zig and can be tested without a
  window. No RPG subsystem is requested from Peas.
- Existing starter and dogfood projects provide public package build recipes,
  portable save blobs, authored text and explicit audio cleanup. Integration
  of those recipes into this game remains to be verified.

## Required issue record

For each demonstrated significant issue retain task, exact reproduction command,
platform/toolchain/build/revision, expected and observed result, API/source
locations, logs/captures/minimal reproduction, classification, severity/impact,
workaround and cost, proposed improvement, resolution/regression and final status.
Do not promote untested expectations into framework defects.
