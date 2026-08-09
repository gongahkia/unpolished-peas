package sim

import (
	"fmt"
	"hash/fnv"
)

type EncounterKind uint8

const (
	EncounterSkirmish EncounterKind = iota
	EncounterShrine
	EncounterElite
	EncounterBoss
)

func (k EncounterKind) String() string {
	switch k {
	case EncounterShrine:
		return "shrine"
	case EncounterElite:
		return "elite"
	case EncounterBoss:
		return "boss"
	default:
		return "skirmish"
	}
}

type Vow uint8

const (
	VowNone Vow = iota
	VowSilence
	VowHumility
	VowCloudbound
)

func (v Vow) String() string {
	switch v {
	case VowSilence:
		return "silence"
	case VowHumility:
		return "humility"
	case VowCloudbound:
		return "cloudbound"
	default:
		return "none"
	}
}

type Companion uint8

const (
	CompanionNone Companion = iota
	CompanionBajie
	CompanionWujing
)

func (c Companion) String() string {
	switch c {
	case CompanionBajie:
		return "Bajie"
	case CompanionWujing:
		return "Wujing"
	default:
		return "none"
	}
}

type RouteNode struct {
	ID          string
	Name        string
	Kind        EncounterKind
	Description string
	Next        []int
}

// Run is a small, authored pilgrimage with seeded branch order. Major bosses
// remain authored; only normal-enemy compositions are remixed.
type Run struct {
	Seed      uint64
	World     *World
	Nodes     []RouteNode
	Current   int
	History   []int
	Vows      []Vow
	Companion Companion
	Completed bool
}

func NewRun(seed uint64) *Run {
	w := NewWorld(seed)
	run := &Run{Seed: seed, World: w, Nodes: pilgrimageRoute(seed), Current: 0}
	if seed%2 == 0 {
		run.Companion = CompanionBajie
	} else {
		run.Companion = CompanionWujing
	}
	w.Companion = run.Companion
	run.startCurrent()
	return run
}

func pilgrimageRoute(seed uint64) []RouteNode {
	firstLeft, firstRight := "bamboo ambush", "river crossing"
	if seed&1 == 1 {
		firstLeft, firstRight = firstRight, firstLeft
	}
	return []RouteNode{
		{ID: "start", Name: "Cloud Gate", Kind: EncounterSkirmish, Description: "A demon patrol blocks the pilgrimage.", Next: []int{1, 2}},
		{ID: "bamboo", Name: firstLeft, Kind: EncounterSkirmish, Description: "Fast yaoguai test spacing and short staff.", Next: []int{3}},
		{ID: "river", Name: firstRight, Kind: EncounterElite, Description: "Archers and a brute control the ford.", Next: []int{3}},
		{ID: "wind_shrine", Name: "Wind Shrine", Kind: EncounterShrine, Description: "Take a vow before Yellow Wind Sage.", Next: []int{4}},
		{ID: "yellow", Name: "Yellow Wind Sage", Kind: EncounterBoss, Description: "Open wind walls with a long staff.", Next: []int{5, 6}},
		{ID: "furnace", Name: "Ashen Furnace", Kind: EncounterElite, Description: "A hot passage of brutes and projectiles.", Next: []int{7}},
		{ID: "lotus", Name: "Lotus Marsh", Kind: EncounterSkirmish, Description: "Small bodies make sparrow movement useful.", Next: []int{7}},
		{ID: "jade_shrine", Name: "Jade Shrine", Kind: EncounterShrine, Description: "Choose a second teaching.", Next: []int{8}},
		{ID: "golden", Name: "Golden Horn King", Kind: EncounterBoss, Description: "Break jade wards in their required form.", Next: []int{9}},
		{ID: "mirror", Name: "Mirror Road", Kind: EncounterElite, Description: "Hair clones redirect the mirror host.", Next: []int{10}},
		{ID: "erlang", Name: "Erlang's Mirror", Kind: EncounterBoss, Description: "Use clones to expose the final seal."},
	}
}

func (r *Run) CurrentNode() RouteNode { return r.Nodes[r.Current] }

func (r *Run) startCurrent() {
	r.World.BeginEncounter()
	node := r.CurrentNode()
	switch node.ID {
	case "start", "bamboo", "lotus":
		r.spawnSkirmish(3)
	case "river", "furnace", "mirror":
		r.spawnElite()
	case "yellow":
		r.World.SpawnBoss("yellow_wind_sage", "Yellow Wind Sage", Vec{X: 470, Y: 175}, 320)
	case "golden":
		r.World.SpawnBoss("golden_horn", "Golden Horn King", Vec{X: 470, Y: 175}, 390)
	case "erlang":
		r.World.SpawnBoss("erlang_mirror", "Erlang's Mirror", Vec{X: 470, Y: 175}, 450)
	case "wind_shrine", "jade_shrine":
		r.World.Won = true
	}
}

func (r *Run) spawnSkirmish(count int) {
	for i := range count {
		x := 120 + float64((r.World.Random()+uint64(i*97))%400)
		y := 70 + float64((r.World.Random()+uint64(i*53))%220)
		kind := EnemyYaoguai
		if i == count-1 {
			switch r.World.Random() % 4 {
			case 0:
				kind = EnemyArcher
			case 1:
				kind = EnemyLancer
			case 2:
				kind = EnemyHexer
			}
		}
		r.World.SpawnEnemy(kind, Vec{X: x, Y: y})
	}
}

func (r *Run) spawnElite() {
	r.spawnSkirmish(2)
	r.World.SpawnEnemy(EnemyArcher, Vec{X: 500, Y: 90})
	r.World.SpawnEnemy(EnemyBrute, Vec{X: 470, Y: 260})
	r.World.SpawnEnemy(EnemyHexer, Vec{X: 145, Y: 85})
}

// Advance follows a selected route edge only after the current encounter is
// cleared. Branch selection is explicit so the route remains replayable.
func (r *Run) Advance(choice int) error {
	if r.Completed {
		return fmt.Errorf("pilgrimage already complete")
	}
	if !r.World.Won {
		return fmt.Errorf("cannot advance before encounter is cleared")
	}
	node := r.CurrentNode()
	if len(node.Next) == 0 {
		r.Completed = true
		return nil
	}
	if choice < 0 || choice >= len(node.Next) {
		return fmt.Errorf("route choice %d is unavailable", choice)
	}
	r.History = append(r.History, r.Current)
	r.Current = node.Next[choice]
	r.startCurrent()
	return nil
}

func (r *Run) ChooseVow(vow Vow) error {
	if r.CurrentNode().Kind != EncounterShrine {
		return fmt.Errorf("vows can only be chosen at shrines")
	}
	if vow == VowNone {
		return fmt.Errorf("choose a teaching, not none")
	}
	if r.World.Vows[vow] {
		return fmt.Errorf("vow of %s is already active", vow)
	}
	r.World.Vows[vow] = true
	r.Vows = append(r.Vows, vow)
	return nil
}

// RestartCurrent retries the current encounter with a fresh deterministic
// world, retaining only run-level choices.
func (r *Run) RestartCurrent() {
	r.World = NewWorld(r.Seed)
	r.World.Companion = r.Companion
	for _, vow := range r.Vows {
		r.World.Vows[vow] = true
	}
	r.startCurrent()
}

// ApplyFrame is the only replay-facing mutation surface for a pilgrimage.
// Route decisions are represented alongside combat input instead of relying on
// UI state, making a whole run reproducible from its seed and ordered frames.
func (r *Run) ApplyFrame(frame RunFrame) error {
	if frame.Restart {
		r.RestartCurrent()
		return nil
	}
	if frame.Vow != VowNone {
		return r.ChooseVow(frame.Vow)
	}
	if frame.Advance {
		return r.Advance(frame.RouteChoice)
	}
	if !r.World.Won && !r.World.Lost && !r.Completed {
		r.World.Step(frame.Input)
	}
	return nil
}

// StateHash combines route-level state with the deterministic encounter hash.
func (r *Run) StateHash() uint64 {
	h := fnv.New64a()
	_, _ = fmt.Fprintf(h, "%d/%d/%d/%t/%d/%x", r.Seed, r.Current, r.Companion, r.Completed, len(r.History), r.World.StateHash())
	for _, vow := range []Vow{VowSilence, VowHumility, VowCloudbound} {
		_, _ = fmt.Fprintf(h, "/%d:%t", vow, r.World.Vows[vow])
	}
	return h.Sum64()
}
