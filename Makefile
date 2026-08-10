.PHONY: run test vet fmt build wasm bosslint

run:
	go run ./example/wukong --mode=playtest

test:
	go test ./...

vet:
	go vet ./...

fmt:
	gofmt -w $$(rg --files -g '*.go')

build:
	mkdir -p bin
	go build -o bin/wukong ./example/wukong

wasm:
	mkdir -p dist
	GOOS=js GOARCH=wasm go build -o dist/wukong.wasm ./example/wukong
	cp "$$(go env GOROOT)/lib/wasm/wasm_exec.js" dist/wasm_exec.js
	cp example/wukong/web/index.html dist/index.html

bosslint:
	go run ./example/wukong/cmd/bosslint ./example/wukong/data/bosses
