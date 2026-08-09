# Boss pattern DSL

Boss sources are compiled from a deliberately small language:

```text
boss yellow_wind_sage {
  phase opening {
    repeat 3 { telegraph sweep 24; attack sweep; wait 18; }
  }
}
```

The pipeline is lexer → parser → AST → semantic validation → compiled pattern.
Its structural commands are `sequence`, `parallel`, and `repeat [count]`; its
atomic commands are `wait`, `attack`, `move`/`movement`/`dash`, `spawn`,
`telegraph`, and `transition`. The compiler reports source positions for
malformed blocks, unknown commands, and empty phases. `go run ./cmd/bosslint
./data/bosses` validates all sources.
