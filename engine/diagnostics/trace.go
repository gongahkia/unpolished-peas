package diagnostics

import (
	"encoding/json"
	"sync"
	"time"
)

// Span records one completed CPU operation relative to a Trace's creation.
// Duration measures host-side work only; it does not imply GPU completion.
type Span struct {
	Name     string
	Started  time.Duration
	Duration time.Duration
}

// Trace is an optional, bounded CPU timeline recorder. It is safe to record
// from multiple goroutines and keeps the newest spans when it reaches capacity.
type Trace struct {
	mu       sync.RWMutex
	origin   time.Time
	capacity int
	spans    []Span
	next     int
	dropped  uint64
}

// NewTrace creates a bounded recorder. Non-positive capacities use 1,024
// spans so callers can opt in without making an unbounded memory commitment.
func NewTrace(capacity int) *Trace {
	if capacity <= 0 {
		capacity = 1024
	}
	return &Trace{origin: time.Now(), capacity: capacity}
}

// Span starts one named CPU span and returns the completion function. Empty
// names and nil traces are ignored, which makes optional instrumentation cheap
// at call sites.
func (t *Trace) Span(name string) func() {
	if t == nil || name == "" {
		return func() {}
	}
	started := time.Now()
	return func() { t.record(name, started, time.Since(started)) }
}

func (t *Trace) record(name string, started time.Time, duration time.Duration) {
	if t == nil || name == "" || duration < 0 {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	span := Span{Name: name, Started: started.Sub(t.origin), Duration: duration}
	if len(t.spans) == t.capacity {
		t.spans[t.next] = span
		t.next = (t.next + 1) % t.capacity
		t.dropped++
		return
	}
	t.spans = append(t.spans, span)
}

// Snapshot returns spans in capture order and the number discarded because the
// bounded recorder reached capacity.
func (t *Trace) Snapshot() (spans []Span, dropped uint64) {
	if t == nil {
		return nil, 0
	}
	t.mu.RLock()
	if len(t.spans) < t.capacity || t.next == 0 {
		spans = append([]Span(nil), t.spans...)
	} else {
		spans = append(spans, t.spans[t.next:]...)
		spans = append(spans, t.spans[:t.next]...)
	}
	dropped = t.dropped
	t.mu.RUnlock()
	return spans, dropped
}

// ChromeJSON returns the Chrome trace-event JSON representation of captured
// CPU spans. A caller can save it as a .json file and open it in Perfetto or
// Chrome's tracing viewer.
func (t *Trace) ChromeJSON() ([]byte, error) {
	spans, _ := t.Snapshot()
	type event struct {
		Name      string `json:"name"`
		Category  string `json:"cat"`
		Phase     string `json:"ph"`
		Timestamp int64  `json:"ts"`
		Duration  int64  `json:"dur"`
		Process   int    `json:"pid"`
		Thread    int    `json:"tid"`
	}
	events := make([]event, 0, len(spans))
	for _, span := range spans {
		events = append(events, event{Name: span.Name, Category: "72", Phase: "X", Timestamp: span.Started.Microseconds(), Duration: span.Duration.Microseconds(), Process: 72, Thread: 1})
	}
	return json.Marshal(struct {
		TraceEvents []event `json:"traceEvents"`
	}{TraceEvents: events})
}
