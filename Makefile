.PHONY: example-run test vet fmt example-build example-wasm first-game-run first-game-build first-game-wasm

example-run:
	go run ./example/wukong --mode=playtest

test:
	go test ./...

vet:
	go vet ./...

fmt:
	gofmt -w $$(rg --files -g '*.go')

example-build:
	mkdir -p bin
	go build -o bin/wukong ./example/wukong

example-wasm:
	mkdir -p dist
	GOOS=js GOARCH=wasm go build -o dist/wukong.wasm ./example/wukong
	cp "$$(go env GOROOT)/lib/wasm/wasm_exec.js" dist/wasm_exec.js
	cp example/wukong/web/index.html dist/index.html

first-game-run:
	go run ./example/first-game

first-game-build:
	mkdir -p bin
	go build -o bin/first-game ./example/first-game

first-game-wasm:
	mkdir -p dist/first-game
	GOOS=js GOARCH=wasm go build -o dist/first-game/first-game.wasm ./example/first-game
	cp "$$(go env GOROOT)/lib/wasm/wasm_exec.js" dist/first-game/wasm_exec.js
	cp example/first-game/web/index.html dist/first-game/index.html
