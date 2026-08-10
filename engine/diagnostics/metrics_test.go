package diagnostics

import (
	"testing"
	"time"
)

func TestRegistryAggregatesSortedMetrics(t *testing.T) {
	registry := NewRegistry()
	if err := registry.Add("draw.calls", 2); err != nil {
		t.Fatal(err)
	}
	if err := registry.Record("frame", time.Millisecond); err != nil {
		t.Fatal(err)
	}
	metrics := registry.Snapshot()
	if len(metrics) != 2 || metrics[0].Name != "draw.calls" || metrics[0].Count != 2 || metrics[1].Total != time.Millisecond {
		t.Fatalf("metrics = %+v", metrics)
	}
}
