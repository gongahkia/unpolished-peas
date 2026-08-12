package diagnostics

import (
	"encoding/json"
	"testing"
	"time"
)

func TestTraceKeepsNewestSpansAtCapacity(t *testing.T) {
	trace := NewTrace(2)
	started := trace.origin
	trace.record("first", started, time.Microsecond)
	trace.record("second", started.Add(time.Microsecond), time.Microsecond)
	trace.record("third", started.Add(2*time.Microsecond), time.Microsecond)
	spans, dropped := trace.Snapshot()
	if dropped != 1 || len(spans) != 2 || spans[0].Name != "second" || spans[1].Name != "third" {
		t.Fatalf("trace snapshot = %+v, dropped=%d", spans, dropped)
	}
}

func TestTraceExportsChromeTraceEvents(t *testing.T) {
	trace := NewTrace(1)
	trace.record("renderer.webgpu.frame", trace.origin.Add(time.Microsecond), 2*time.Microsecond)
	data, err := trace.ChromeJSON()
	if err != nil {
		t.Fatalf("ChromeJSON() error = %v", err)
	}
	var decoded struct {
		TraceEvents []struct {
			Name     string `json:"name"`
			Phase    string `json:"ph"`
			Duration int64  `json:"dur"`
		} `json:"traceEvents"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("trace JSON is invalid: %v", err)
	}
	if len(decoded.TraceEvents) != 1 || decoded.TraceEvents[0].Name != "renderer.webgpu.frame" || decoded.TraceEvents[0].Phase != "X" || decoded.TraceEvents[0].Duration != 2 {
		t.Fatalf("trace events = %+v", decoded.TraceEvents)
	}
}
