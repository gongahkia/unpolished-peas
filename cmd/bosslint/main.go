package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/gongahkia/72/internal/bossdsl"
)

func main() {
	directory := "data/bosses"
	if len(os.Args) > 1 {
		directory = os.Args[1]
	}
	paths, err := filepath.Glob(filepath.Join(directory, "*.boss"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	sort.Strings(paths)
	if len(paths) == 0 {
		fmt.Fprintf(os.Stderr, "no .boss files in %s\n", directory)
		os.Exit(1)
	}
	for _, path := range paths {
		source, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		file, err := bossdsl.Parse(string(source))
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
			os.Exit(1)
		}
		if _, err := bossdsl.Compile(file); err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
			os.Exit(1)
		}
		fmt.Printf("ok %s (%s)\n", path, file.Boss.Name)
	}
}
