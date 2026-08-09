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
	GOOS=js GOARCH=wasm go build -o dist/journey.wasm ./cmd/game

bosslint:
	go run ./cmd/bosslint ./data/bosses
