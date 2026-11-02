# Neon Siege authored assets

`neon-siege.png` is the compact 32×16 sprite sheet used by the dogfood game.
It contains two 8×8 player walk frames plus enemy, projectile, and pickup
sprites. It is repository-authored pixel art; regenerate it deliberately with
`zig run script/generate_neon_siege_sprite_sheet.zig` from the
repository root. The generator is kept solely for provenance, not as a game
asset pipeline.

`neon-siege.ttf` is the Basic typeface from Sorkin Type Co. It is distributed
under the SIL Open Font License 1.1; `OFL.txt` is its required notice. Native
and browser packages embed the font bytes into the executable/Wasm and install
the notice under `licenses/` rather than copying an `assets/` runtime tree.

`embedded_assets.zig` embeds these source files at build time. The resulting
game uses no asset-directory lookup at runtime.

`neon-loop.ogg` is a repository-authored two-second three-sine chord produced
by `script/generate_neon_siege_music.sh`. It contains no sampled or
third-party music. The game embeds the encoded Vorbis bytes and decodes only a
bounded PCM window while it plays.
