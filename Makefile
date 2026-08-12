.PHONY: example-run test vet fmt benchmark benchmark-webgpu benchmark-report release-dry-run example-build example-wasm first-game-run first-game-build first-game-wasm ui-sample-run ui-sample-build ui-sample-wasm

example-run:
	go run ./example/wukong --mode=playtest

test:
	go test ./...

vet:
	go vet ./...

fmt:
	gofmt -w $$(rg --files -g '*.go')

benchmark:
	go test -run '^$$' -bench '^BenchmarkReference' -benchmem -count=5 ./engine/render

benchmark-webgpu:
	go test -run '^$$' -bench '^BenchmarkHeadlessTileMapScene$$' -benchmem -count=5 ./engine/render/webgpu

benchmark-report:
	test -n "$(REPORT)"
	./scripts/capture-render-benchmark.sh "$(REPORT)"

release-dry-run:
	test -n "$(VERSION)"
	./scripts/release-dry-run.sh "$(VERSION)"

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

ui-sample-run:
	go run ./example/ui

ui-sample-build:
	mkdir -p bin
	go build -o bin/ui-sample ./example/ui

ui-sample-wasm:
	mkdir -p dist/ui-sample
	GOOS=js GOARCH=wasm go build -o dist/ui-sample/ui-sample.wasm ./example/ui
	cp "$$(go env GOROOT)/lib/wasm/wasm_exec.js" dist/ui-sample/wasm_exec.js
	cp example/ui/web/index.html dist/ui-sample/index.html
