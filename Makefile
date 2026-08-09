.PHONY: run test vet fmt build wasm bosslint

run:
	go run ./cmd/game --mode=playtest

test:
	go test ./...

vet:
	go vet ./...

fmt:
	gofmt -w $$(rg --files -g '*.go')

build:
	go build ./cmd/game

wasm:
	mkdir -p dist
	GOOS=js GOARCH=wasm go build -o dist/72.wasm ./cmd/game
	cp "$$(go env GOROOT)/lib/wasm/wasm_exec.js" dist/wasm_exec.js
	cp web/index.html dist/index.html

bosslint:
	go run ./cmd/bosslint ./data/bosses
