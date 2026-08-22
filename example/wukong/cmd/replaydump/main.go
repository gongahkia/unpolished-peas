package main

import (
	"fmt"
	"os"

	"github.com/gongahkia/72/example/wukong/internal/sim"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: replaydump FILE.replay.json")
		os.Exit(2)
	}
	replay, err := sim.LoadReplay(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	last := uint64(0)
	if len(replay.Hashes) > 0 {
		last = replay.Hashes[len(replay.Hashes)-1]
	}
	if _, err := replay.PlayRun(); err != nil {
		fmt.Fprintf(os.Stderr, "replay verification failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("version=%s seed=%d frames=%d final_hash=%x verified\n", replay.Version, replay.Seed, len(replay.Frames), last)
}
