// Package bosses embeds the authored boss sources for native and WASM builds.
package bosses

import (
	"embed"
	"fmt"

	"github.com/gongahkia/72/example/wukong/internal/bossdsl"
)

//go:embed *.boss
var sources embed.FS

func Program(id string) (*bossdsl.Program, error) {
	source, err := sources.ReadFile(id + ".boss")
	if err != nil {
		return nil, fmt.Errorf("read boss %q: %w", id, err)
	}
	file, err := bossdsl.Parse(string(source))
	if err != nil {
		return nil, fmt.Errorf("parse boss %q: %w", id, err)
	}
	program, err := bossdsl.Compile(file)
	if err != nil {
		return nil, fmt.Errorf("compile boss %q: %w", id, err)
	}
	return program, nil
}

func MustProgram(id string) *bossdsl.Program {
	program, err := Program(id)
	if err != nil {
		panic(err)
	}
	return program
}
