.PHONY: example-run test vet fmt example-build example-wasm

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
