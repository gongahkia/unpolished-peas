package sim

// ReferenceReplaySeed is the fixed procedural seed used by the Wukong proof
// replay and benchmark. It is game evidence, not an engine compatibility API.
const ReferenceReplaySeed uint64 = 0x72c0ffee

// ReferenceReplay records a stable 240-tick input sequence against the fixed
// proof seed. It gives release checks a portable replay artifact without
// depending on an interactive host or renderer.
func ReferenceReplay() *Replay {
	world := NewRunWorld(ReferenceReplaySeed)
	replay := NewReplay(ReferenceReplaySeed)
	for tick := range 240 {
		input := InputFrame{MoveX: 1, AimX: 1}
		if tick%48 < 8 {
			input.Jump = true
		}
		if tick%96 >= 72 {
			input.Down = true
		}
		if tick%60 >= 40 && tick%60 < 48 {
			input.Roll = true
		}
		replay.Record(world, input)
	}
	return replay
}
