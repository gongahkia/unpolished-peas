// Command replaygen writes Wukong's fixed deterministic proof replay.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/gongahkia/72/example/wukong/internal/sim"
)

func main() {
	output := flag.String("out", "", "required replay output path")
	flag.Parse()
	if *output == "" || flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "usage: replaygen -out FILE.replay.json")
		os.Exit(2)
	}
	if err := sim.SaveReplay(*output, sim.ReferenceReplay()); err != nil {
		fmt.Fprintln(os.Stderr, "replaygen:", err)
		os.Exit(1)
	}
}
