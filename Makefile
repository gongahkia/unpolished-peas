.PHONY: run test vet fmt build wasm bosslint

run:
	go run ./cmd/game

test:
	go test ./...

vet:
	go vet ./...

fmt:
	gofmt -w $$(find . -name '*.go' -not -path './vendor/*')

build:
	go build ./cmd/game

wasm:
	mkdir -p dist
	GOOS=js GOARCH=wasm go build -o dist/journey.wasm ./cmd/game
	cp "$$(go env GOROOT)/lib/wasm/wasm_exec.js" dist/wasm_exec.js
	cp web/index.html dist/index.html

bosslint:
	go run ./cmd/bosslint ./data/bosses
