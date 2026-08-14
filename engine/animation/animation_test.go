package animation

import (
	"math"
	"reflect"
	"testing"
	"time"

	"github.com/gongahkia/72/engine"
)

func testClip(t *testing.T, playback Playback) Clip {
	t.Helper()
	clip, err := NewClip([]Frame{
		{Source: engine.Rect{X: 0, W: 8, H: 8}, Duration: 10 * time.Millisecond, Event: "zero"},
		{Source: engine.Rect{X: 8, W: 8, H: 8}, Duration: 20 * time.Millisecond, Event: "one"},
		{Source: engine.Rect{X: 16, W: 8, H: 8}, Duration: 30 * time.Millisecond, Event: "two"},
	}, playback)
	if err != nil {
		t.Fatal(err)
	}
	return clip
}

func TestNewClipValidatesAndCopiesFrames(t *testing.T) {
	if _, err := NewClip(nil, Loop); err == nil {
		t.Fatal("empty clip succeeded")
	}
	for _, frame := range []Frame{
		{Source: engine.Rect{W: 1, H: 1}},
		{Source: engine.Rect{W: -1, H: 1}, Duration: time.Millisecond},
		{Source: engine.Rect{X: math.NaN(), W: 1, H: 1}, Duration: time.Millisecond},
	} {
		if _, err := NewClip([]Frame{frame}, Loop); err == nil {
			t.Fatalf("invalid frame %+v succeeded", frame)
		}
	}
	frames := []Frame{{Source: engine.Rect{W: 1, H: 1}, Duration: time.Millisecond}}
	clip, err := NewClip(frames, Loop)
	if err != nil {
		t.Fatal(err)
	}
	frames[0].Source.W = 9
	if got := clip.Frames()[0].Source.W; got != 1 {
		t.Fatalf("clip retained caller mutation: %g", got)
	}
}

func TestPlayerLoopReportsEveryCrossedFrameInOrder(t *testing.T) {
	player, err := NewPlayer(testClip(t, Loop))
	if err != nil {
		t.Fatal(err)
	}
	events, err := player.Advance(70 * time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	want := []Event{{Frame: 1, Name: "one"}, {Frame: 2, Name: "two"}, {Frame: 0, Name: "zero"}, {Frame: 1, Name: "one"}}
	if !reflect.DeepEqual(events, want) || player.Frame() != 1 || player.Source().X != 8 {
		t.Fatalf("loop advance = events=%+v frame=%d source=%+v, want events=%+v frame=1", events, player.Frame(), player.Source(), want)
	}
	if events, err := player.Advance(0); err != nil || len(events) != 0 {
		t.Fatalf("zero advance = %+v, %v", events, err)
	}
	if _, err := player.Advance(-time.Millisecond); err == nil {
		t.Fatal("negative advance succeeded")
	}
}

func TestPlayerOnceHoldsFinalFrameAfterFinalDuration(t *testing.T) {
	player, err := NewPlayer(testClip(t, Once))
	if err != nil {
		t.Fatal(err)
	}
	events, err := player.Advance(60 * time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if want := []Event{{Frame: 1, Name: "one"}, {Frame: 2, Name: "two"}}; !reflect.DeepEqual(events, want) || !player.Finished() || player.Frame() != 2 {
		t.Fatalf("once advance = events=%+v finished=%t frame=%d", events, player.Finished(), player.Frame())
	}
	player.Restart()
	if player.Finished() || player.Frame() != 0 {
		t.Fatalf("restart = finished=%t frame=%d", player.Finished(), player.Frame())
	}
}

func TestPlayerPingPongDoesNotDuplicateEndpoints(t *testing.T) {
	player, err := NewPlayer(testClip(t, PingPong))
	if err != nil {
		t.Fatal(err)
	}
	events, err := player.Advance(100 * time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	want := []Event{{Frame: 1, Name: "one"}, {Frame: 2, Name: "two"}, {Frame: 1, Name: "one"}, {Frame: 0, Name: "zero"}, {Frame: 1, Name: "one"}}
	if !reflect.DeepEqual(events, want) || player.Frame() != 1 {
		t.Fatalf("ping-pong advance = events=%+v frame=%d, want events=%+v frame=1", events, player.Frame(), want)
	}
}

func TestPlayerRejectsUnboundedLoopAdvanceBeforeMutation(t *testing.T) {
	player, err := NewPlayer(testClip(t, Loop))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := player.Advance(time.Duration(maximumAdvanceTransitions+1) * 10 * time.Millisecond); err == nil {
		t.Fatal("unbounded loop advance succeeded")
	}
	if player.Frame() != 0 || player.Finished() {
		t.Fatalf("rejected advance mutated player: frame=%d finished=%t", player.Frame(), player.Finished())
	}
}
