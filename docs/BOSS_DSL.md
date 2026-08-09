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
The compiler reports source positions for malformed blocks, unknown attacks,
and empty phases. `go run ./cmd/bosslint ./data/bosses` validates all sources.
