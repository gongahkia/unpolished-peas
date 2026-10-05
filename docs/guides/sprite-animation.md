# Deterministic sprite-frame animation

`graphics.SpriteAnimationClip` and `graphics.SpriteAnimationPlayer` are a
small, game-owned way to select Atlas frames. They are for ordinary sprite
sheets, not animation graphs, tweening, skeletal animation, or gameplay state
machines.

Define immutable frame steps next to the game’s Atlas data. Each `ticks` value
is a positive count of fixed simulation updates, not seconds or wall-clock
time:

```zig
const up = @import("unpolished-peas");

const walk_steps = [_]up.graphics.SpriteAnimationStep{
    .{ .frame = .{ .index = 0 }, .ticks = 6 },
    .{ .frame = .{ .index = 1 }, .ticks = 6 },
};
const walk = up.graphics.SpriteAnimationClip{
    .steps = &walk_steps,
    .mode = .loop,
};
```

The clip borrows the static step slice; it owns no Atlas, `Image`, renderer, or
allocation. Construct the mutable player once during `init` and retain it in
your game state:

```zig
player_animation = try up.graphics.SpriteAnimationPlayer.init(&walk);
```

`init` validates empty clips and zero-duration steps. A clip uses existing
`assets.AtlasFrameHandle` values, so it deliberately does not own an Atlas.
Call `clip.validateForAtlas(atlas)` once during initialization when you want a
bad static frame index to be a recoverable load error.

## Advance in fixed update, draw the current frame

Call `advance(1)` once per fixed `Game.update`. Decide idle/walk/attack in
ordinary game code; the helper never contains state-machine rules. `play`
always selects and restarts its argument, so `isCurrentClip` makes a
per-update choice preserve progress when the desired clip is already active:

```zig
const wanted = if (moving) &walk else &idle;
if (!player_animation.isCurrentClip(wanted)) {
    try player_animation.play(wanted);
}
player_animation.advance(1);
```

Then draw the returned frame through the normal Atlas API. Animation has no
position, scale, tint, flip, or renderer ownership:

```zig
world_canvas.drawAtlasFrame(
    atlas,
    player_animation.currentFrame(),
    player_position,
    .{ .origin = .center },
);
```

Do not advance in `draw`. A presentation frame with zero updates leaves the
player unchanged; a catch-up presentation frame with three updates advances
the player three times. The same seed, input replay, and fixed updates
therefore select the same frames in native, browser, and headless runs.

At the default 60 Hz host rate, six ticks are 100 ms. Tick clips intentionally
follow the game’s configured fixed rate: changing that rate changes their
real-time speed. This keeps the v1 helper integer-only and avoids accumulated
floating-point timing drift.

## Playback behavior

- `.loop` wraps from the final step to the first.
- `.once` stays on the final frame and reports `isFinished()` after it reaches
  that frame’s duration.
- `pause()` preserves progress; `resumePlayback()` continues it. (`resume` is
  a Zig keyword.)
- `restart()` selects the first step, clears progress, unpauses, and clears
  completion.
- `play(&other_clip)` always restarts the new clip, including when it is the
  same pointer. A copied `SpriteAnimationPlayer` is an independent copy of
  playback state.

All player operations are allocation-free after initialization. Large loop
advances skip complete cycles rather than iterating one simulation tick at a
time.

## Atlas and asset reloads

The player retains only an Atlas-frame handle. Existing Atlas/Canvas drawing
continues to resolve the actual source rectangle. Native developer image
reload keeps these clips valid when the replacement image has compatible Atlas
metadata; an incompatible replacement remains rejected by the existing reload
path. No animation-specific hot-reload registry exists.

See [Neon Siege](../../dogfood/neon-siege/src/art.zig) for static clips and its
[game update/draw code](../../dogfood/neon-siege/src/game.zig) for the compiled
idle/walk integration.

## Limits

This facility intentionally has no ping-pong mode, reverse playback,
per-frame callbacks, frame-event tracks, transform animation, blend trees, or
animation state-machine framework. Keep gameplay events and transitions in
the game.
