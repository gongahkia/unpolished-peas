package sim

import (
	"encoding/json"
	"fmt"
	"os"
)

// Replay is a portable deterministic input recording for one encounter. The
// caller recreates its authored encounter from Seed, then Play verifies the
// hash after every tick rather than merely trusting a final visual result.
type Replay struct {
	Version string       `json:"version"`
	Seed    uint64       `json:"seed"`
	Frames  []InputFrame `json:"frames"`
	Hashes  []uint64     `json:"hashes"`
}

// RunFrame records either one combat input tick or an explicit pilgrimage UI
// decision. RouteChoice is used only when Advance is true.
type RunFrame struct {
	Input       InputFrame `json:"input"`
	Advance     bool       `json:"advance,omitempty"`
	RouteChoice int        `json:"route_choice,omitempty"`
	Vow         Vow        `json:"vow,omitempty"`
	Restart     bool       `json:"restart,omitempty"`
}

// RunReplay extends encounter replay with route choices, vows, and retries.
// It therefore recreates a full pilgrimage from only a version, seed, and
// ordered frames.
type RunReplay struct {
	Version string     `json:"version"`
	Seed    uint64     `json:"seed"`
	Frames  []RunFrame `json:"frames"`
	Hashes  []uint64   `json:"hashes"`
}

func NewRunReplay(seed uint64) *RunReplay {
	return &RunReplay{Version: SimulationVersion, Seed: seed}
}

func (r *RunReplay) Record(run *Run, frame RunFrame) error {
	if err := run.ApplyFrame(frame); err != nil {
		return err
	}
	r.Frames = append(r.Frames, frame)
	r.Hashes = append(r.Hashes, run.StateHash())
	return nil
}

func (r *RunReplay) Validate() error {
	if r.Version != SimulationVersion {
		return fmt.Errorf("run replay version %q is incompatible with %q", r.Version, SimulationVersion)
	}
	if r.Seed == 0 {
		return fmt.Errorf("run replay seed must not be zero")
	}
	if len(r.Frames) != len(r.Hashes) {
		return fmt.Errorf("run replay has %d frames but %d state hashes", len(r.Frames), len(r.Hashes))
	}
	return nil
}

func (r *RunReplay) Play() (*Run, error) {
	if err := r.Validate(); err != nil {
		return nil, err
	}
	run := NewRun(r.Seed)
	for tick, frame := range r.Frames {
		if err := run.ApplyFrame(frame); err != nil {
			return nil, fmt.Errorf("replay frame %d: %w", tick+1, err)
		}
		if hash := run.StateHash(); hash != r.Hashes[tick] {
			return nil, fmt.Errorf("run replay diverged at tick %d: got %x want %x", tick+1, hash, r.Hashes[tick])
		}
	}
	return run, nil
}

func SaveRunReplay(path string, replay *RunReplay) error {
	if err := replay.Validate(); err != nil {
		return err
	}
	data, err := json.MarshalIndent(replay, "", "  ")
	if err != nil {
		return fmt.Errorf("encode run replay: %w", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return fmt.Errorf("write run replay: %w", err)
	}
	return nil
}

func LoadRunReplay(path string) (*RunReplay, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read run replay: %w", err)
	}
	var replay RunReplay
	if err := json.Unmarshal(data, &replay); err != nil {
		return nil, fmt.Errorf("decode run replay: %w", err)
	}
	if err := replay.Validate(); err != nil {
		return nil, err
	}
	return &replay, nil
}

func NewReplay(seed uint64) *Replay {
	return &Replay{Version: SimulationVersion, Seed: seed}
}

func (r *Replay) Record(world *World, input InputFrame) {
	world.Step(input)
	r.Frames = append(r.Frames, input)
	r.Hashes = append(r.Hashes, world.StateHash())
}

func (r *Replay) Validate() error {
	if r.Version != SimulationVersion {
		return fmt.Errorf("replay version %q is incompatible with %q", r.Version, SimulationVersion)
	}
	if r.Seed == 0 {
		return fmt.Errorf("replay seed must not be zero")
	}
	if len(r.Frames) != len(r.Hashes) {
		return fmt.Errorf("replay has %d frames but %d state hashes", len(r.Frames), len(r.Hashes))
	}
	return nil
}

func (r *Replay) Play(world *World) error {
	if err := r.Validate(); err != nil {
		return err
	}
	if world.Seed != r.Seed {
		return fmt.Errorf("replay seed %d does not match world seed %d", r.Seed, world.Seed)
	}
	for tick, input := range r.Frames {
		world.Step(input)
		if hash := world.StateHash(); hash != r.Hashes[tick] {
			return fmt.Errorf("replay diverged at tick %d: got %x want %x", tick+1, hash, r.Hashes[tick])
		}
	}
	return nil
}

func SaveReplay(path string, replay *Replay) error {
	if err := replay.Validate(); err != nil {
		return err
	}
	data, err := json.MarshalIndent(replay, "", "  ")
	if err != nil {
		return fmt.Errorf("encode replay: %w", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return fmt.Errorf("write replay: %w", err)
	}
	return nil
}

func LoadReplay(path string) (*Replay, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read replay: %w", err)
	}
	var replay Replay
	if err := json.Unmarshal(data, &replay); err != nil {
		return nil, fmt.Errorf("decode replay: %w", err)
	}
	if err := replay.Validate(); err != nil {
		return nil, err
	}
	return &replay, nil
}
