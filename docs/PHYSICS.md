# 2D physics boundary

`engine/physics` provides a small deterministic AABB collision world for
gameplay systems. It is deliberately not a general rigid-body engine.

## Stepping and determinism

Create a world with `physics.NewWorld()` for the standard 60 Hz cadence, or
with `physics.NewWorldWithConfig` for an explicit fixed duration. Call
`StepFixed` exactly once per simulation tick. `Step(dt)` exists for controlled
tests and applications that own their own fixed accumulator; pass the same,
finite duration for every comparable tick.

Bodies and pair processing are ordered by their monotonically assigned IDs.
For equal initial state, body-operation order, and step durations, a world
produces the same body and contact ordering on the same 72 build and target.
72 does not claim bit-identical results across different Go toolchains,
architectures, or floating-point implementations. Do not use a variable frame
duration as replay or network-simulation input.

## Bodies, layers, and queries

Every body contains one positive, finite `AABB`, position, velocity, nonzero
collision `Layer`, and collision `Mask`. A pair participates only when each
body's mask includes the other's layer. A zero mask is valid and opts a body
out of pair collision; a zero layer is rejected because it cannot be matched.

`World.Overlap` is an immediate AABB query. It filters bodies by a layer mask
and returns IDs in creation order. It has no sweep, raycast, shape cast, or
allocation-free callback form. Queries with invalid geometry, position, or a
zero layer mask return no IDs.

## Contacts and sensors

`Contacts` returns one lifecycle event per pair from the latest successful
step, ordered by `(First, Second)` body ID:

- `ContactBegin` is the first observed overlap.
- `ContactStay` is an overlap that also existed in the previous step.
- `ContactEnd` is an overlap that disappeared, including after a body is
  removed before the next step.

The contact normal points from `First` to `Second` for begin and stay events;
an end event retains its last observed normal. If either body is a `Sensor`,
the event's `Sensor` field is true and no positional or velocity response is
applied. Sensor contacts are the supported trigger mechanism.

## Supported and unsupported behavior

The current solver integrates dynamic and kinematic linear velocity, resolves
axis-aligned penetration, and zeros velocity along the resolution axis. Static
bodies never move. It does not provide gravity, forces, mass, restitution,
friction, rotation, continuous collision detection, constraints, broad-phase
acceleration, compound shapes, polygon/circle geometry, or a third-party
physics-backend adapter.

Those omissions are intentional extension seams. Future shapes or alternate
backends must remain behind engine-owned types and preserve the documented
fixed-step, layer/mask, query, and contact-lifecycle semantics. They must not
reinterpret `AABB`, expose a dependency's body handle, or silently change the
ordering contract of existing worlds.
