# Architecture decision records

An architecture decision record (ADR) captures a durable technical direction
that would otherwise be easy to reverse accidentally: a public boundary,
dependency, ownership model, platform claim, distribution process, or
cross-cutting lifecycle rule. It is not a changelog or a design diary.

## Creating an ADR

1. Open an issue or design discussion that states the decision and alternatives.
2. Add the next zero-padded file, for example
   `docs/adr/0003-short-decision-name.md`. Do not renumber existing records.
3. Start with `Status` (`proposed`, `accepted`, `superseded`, or `rejected`)
   and `Date`, then document context, decision, alternatives/evidence, and
   consequences. State what the decision does not claim when evidence is incomplete.
4. Link the ADR from affected package documentation and update the README if it
   changes project-wide direction.
5. Obtain review before marking it accepted. A rejected ADR remains valuable:
   record the evidence gap and the replacement experiment or condition that
   would reopen it.

For a dependency or platform decision, pin versions and describe licensing,
artifacts, target coverage, error behavior, operational ownership, and the
verification matrix. A compile-only result is not a runtime support claim.

## Current records

- [ADR 0003](0003-engine-owned-webgpu-renderer.md) selects the low-level
  binding used only by 72's engine-owned host and renderer.
- [ADR 0001](0001-webgpu-renderer-boundary.md) defines the backend-private,
  WebGPU-shaped renderer boundary.
- [ADR 0002](0002-webgpu-dependency-decision.md) is superseded by ADR 0003.
