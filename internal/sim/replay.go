package sim

import (
	"encoding/json"
	"fmt"
	"os"
)

// Replay records the complete deterministic validation encounter input stream.
type Replay struct {
	Version string       `json:"version"`
	Seed    uint64       `json:"seed"`
	Frames  []InputFrame `json:"frames"`
	Hashes  []uint64     `json:"hashes"`
}

func NewReplay(seed uint64) *Replay { return &Replay{Version: SimulationVersion, Seed: seed} }

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
		return fmt.Errorf("replay has %d frames but %d hashes", len(r.Frames), len(r.Hashes))
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

func (r *Replay) PlayValidation() (*World, error) {
	w := NewValidationWorld(r.Seed)
	return w, r.Play(w)
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
