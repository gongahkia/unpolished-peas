# Local two-player chess

This is a complete, untimed local chess example for two people sharing a
device. The same `GameProtocol` game runs on desktop and in a browser:

```sh
zig build run-chess -Doptimize=ReleaseFast
zig build web-chess -Dbrowser-optimize=ReleaseFast
python3 -m http.server 8000 --directory zig-out/chess
```

Open `http://localhost:8000/?renderer=webgl2` for browser play. The normal browser
shell provides its Start/focus controls. This example has no AI opponent,
online multiplayer, chess clocks or persistent match saves.

Click a piece and then a marked destination. Arrows move a board cursor;
Space or Enter selects/moves. White moves first. A checked king is marked red,
the selected square gold, and the last move muted gold. Legal quiet moves
have dots; captures have an outlined destination.

- **Promotion:** choose Queen, Rook, Bishop or Knight in the panel, or press
  Q/R/B/N. The move waits for that choice. Escape cancels the pending move.
- **Flip board / F:** change the view without changing whose turn it is.
- **Undo / U:** take back a move or terminal decision, retaining up to the
  last 64 actions. Castling rights, en passant and repetition state are restored.
- **New game:** confirm to clear the current game and undo history.
- **Resign:** confirm to concede for the player whose turn it is.
- **Draw options:** agree a draw, or indicate an intended move for a repetition/
  fifty-move claim. If the current position already permits a claim, the button
  says **Claim draw**. An invalid intended claim leaves the move unplayed.

The rules cover legal king safety, castling on both sides, en passant,
four promotion choices, checkmate and stalemate. Repetition identity includes
turn, castling rights and legally usable en passant; it compares position
bytes directly, without hash collisions. Threefold/fifty-move claims and
automatic fivefold/seventy-five-move draws follow the relevant distinctions
in the [FIDE Laws of Chess](https://handbook.fide.com/chapter/e012023).
Checkmate takes priority over the automatic seventy-five-move draw.

Automatic material draws recognize kings alone, a single minor piece against
a king, and bishops confined to the same square color. It does not solve
every possible blocked/dead position; players can agree a draw in those cases.
This is a casual digital game, without over-the-board touch-move, arbiters or
tournament administration.

## How it exercises Peas

[The rules](../../examples/chess/rules.zig) are ordinary Zig with no framework
or platform imports. [The game](../../examples/chess_game.zig) owns selection,
promotion, undo and result handling. [The desktop wrapper](../../examples/chess.zig)
only delegates the callbacks to the native host.

The board and pieces use Canvas primitives. Existing Source Sans 3 assets
supply authored text; instructions are prepared once at initialization. No
new image dependency or engine subsystem is required. Input, coordinate
mapping, fixed updates and browser presentation use the existing APIs.

Game history is bounded: 64 undo snapshots and 151 reversible-position
identities per match state. Pawn moves/captures reset repetition history;
the automatic seventy-five-move rule bounds the remaining sequence.
Preparing resources allocates; moving pieces and drawing reuse owned storage.
Layouts are released before their borrowed font collection.

## Validation

```sh
zig build test-chess -Doptimize=ReleaseFast -j2 --summary all
zig build test-browser-chess -Doptimize=ReleaseFast -Dbrowser-optimize=ReleaseFast -j2 --summary all
```

The rules checks enumerate 500,117 leaf positions across six standard move-tree
references, including positions used by the
[official Stockfish perft suite](https://github.com/official-stockfish/Stockfish/blob/master/tests/perft.sh).
Native and Wasm execute the same independent implementation. Targeted checks
also cover pinned en passant, promotion, castling through check, mate,
stalemate, repetition, move-count draws and checkmate priority.

Headless game tests cover illegal-move rejection, a complete game, undo,
promotion waiting, flipped pointer coordinates and allocation-free drawing.
The real Chromium check plays checkmate, castling for both players, en
passant, underpromotion and a threefold claim through the UI. It also checks
keyboard play, flip, undo, restart and resignation. Initial and mate frames
are compared byte-for-byte with native CPU references.

Artifacts, renderer/version metadata, screenshots, RGBA references and logs
are written to `zig-out/diagnostics/chess/`. Install the pinned automation
dependency as described in [browser authoring](browser-authoring.md).
The [example review](../reviews/2026-11-07-local-chess-example.md) records
the observed native/browser checks and visual review boundaries.
