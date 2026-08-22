package sim

import "testing"

func TestReferenceReplayVerifiesItsFixedRun(t *testing.T) {
	replay := ReferenceReplay()
	if err := replay.Validate(); err != nil {
		t.Fatal(err)
	}
	world, err := replay.PlayRun()
	if err != nil {
		t.Fatal(err)
	}
	const expectedFinalHash uint64 = 0xb15b8997a772a891
	if got := world.StateHash(); got != expectedFinalHash {
		t.Fatalf("reference replay final hash = %x, want %x", got, expectedFinalHash)
	}
}

func BenchmarkReferenceReplay(b *testing.B) {
	replay := ReferenceReplay()
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		if _, err := replay.PlayRun(); err != nil {
			b.Fatal(err)
		}
	}
}
