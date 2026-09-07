# Tutorial: build a playable cartridge

This builds a complete source-only catching game, runs it locally, and exports one offline HTML
file. Commands assume the repository toolchain from the README.

## 1. Create the project

```sh
cargo run -p px240c-cli -- new relay-catch --title "RELAY CATCH"
```

Keep the generated `cart.toml`. Replace `relay-catch/src/main.pxl` with:

```pxl
// RELAY CATCH
// Made by @gongahkia

enum Mode:
  Title
  Play
  Win
  Lose

state mode: Mode = Mode.Title
state paddle_x: Int = 104
state signal_x: Int = 120
state signal_y: Int = 18
state catches: Int = 0

fn next_signal() -> Unit:
  signal_x = rng_int(12, 228)
  signal_y = 18

on start:
  next_signal()

on update:
  if mode == Mode.Title:
    if btnp(pad1, a):
      catches = 0
      mode = Mode.Play
      next_signal()
  elif mode == Mode.Play:
    if btn(pad1, left):
      paddle_x -= 3
    if btn(pad1, right):
      paddle_x += 3
    if paddle_x < 0:
      paddle_x = 0
    if paddle_x > 208:
      paddle_x = 208
    signal_y += 2
    if signal_y >= 126:
      if signal_x >= paddle_x and signal_x < paddle_x + 32:
        catches += 1
        if catches >= 8:
          mode = Mode.Win
        else:
          next_signal()
      else:
        mode = Mode.Lose
  elif btnp(pad1, a):
    mode = Mode.Title

on draw:
  clear(25)
  if mode == Mode.Title:
    print("RELAY CATCH", 87, 48, 15)
    print("ARROWS MOVE", 88, 70, 23)
    print("Z TO START", 91, 88, 11)
  elif mode == Mode.Play:
    circle_fill(signal_x, signal_y, 4, 15)
    rect_fill(paddle_x, 132, 32, 5, 23)
    rect(8, 8, catches * 24, 5, 11)
  elif mode == Mode.Win:
    print("SIGNAL LOCKED", 82, 62, 23)
    print("Z TO REPLAY", 88, 82, 7)
  else:
    print("SIGNAL MISSED", 82, 62, 11)
    print("Z TO RETRY", 91, 82, 7)
```

PXCL uses two-space indentation, explicit persistent-state types, inferred local types, and
half-open ranges. `rng_int` is deterministic and `btnp` is true only on the press transition.

## 2. Check, format, and run

```sh
cargo run -p px240c-cli -- check relay-catch
cargo run -p px240c-cli -- fmt --check relay-catch/src/main.pxl
cargo run -p px240c-cli -- run relay-catch
```

`run` writes `relay-catch/dist/relay-catch.html` and opens it through `xdg-open`. Use `--no-open` in
CI. In the browser Studio, `import` accepts the packed file produced below; `edit`, `run`, `debug`,
and `inspect` then operate on the same compiler representation.

## 3. Pack and export

```sh
cargo run -p px240c-cli -- pack relay-catch
cargo run -p px240c-cli -- export html relay-catch
```

The `.pxc` contains the original PXCL, compiled JavaScript, source map, integrity inventory, and
manifest. The standalone HTML `SOURCE` button shows the original module and needs no server after
download. Add source-visible JSON graphics or synth assets using [ASSETS.md](ASSETS.md), declare
them in `cart.toml`, and reference them as typed handles such as `#hero`.
