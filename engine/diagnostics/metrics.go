// Package diagnostics provides runtime-safe counters and duration summaries.
package diagnostics

import (
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"
)

// Metric is a point-in-time diagnostic value.
type Metric struct {
	Name  string
	Count uint64
	Total time.Duration
}

// Registry collects named counters and durations. It is safe for concurrent use.
type Registry struct {
	mu      sync.RWMutex
	metrics map[string]Metric
}

// NewRegistry creates an empty registry.
func NewRegistry() *Registry { return &Registry{metrics: make(map[string]Metric)} }

// Add increments a named counter.
func (r *Registry) Add(name string, amount uint64) error {
	if name == "" {
		return fmt.Errorf("metric name must not be empty")
	}
	r.mu.Lock()
	metric := r.metrics[name]
	metric.Name, metric.Count = name, metric.Count+amount
	r.metrics[name] = metric
	r.mu.Unlock()
	return nil
}

// Set replaces the point-in-time count for name. It preserves any durations
// recorded for the same name, though callers should normally use distinct
// names for counters, gauges, and durations.
func (r *Registry) Set(name string, value uint64) error {
	if name == "" {
		return fmt.Errorf("metric name must not be empty")
	}
	r.mu.Lock()
	metric := r.metrics[name]
	metric.Name, metric.Count = name, value
	r.metrics[name] = metric
	r.mu.Unlock()
	return nil
}

// Record adds one duration sample to name and increments its count.
func (r *Registry) Record(name string, duration time.Duration) error {
	if name == "" {
		return fmt.Errorf("metric name must not be empty")
	}
	if duration < 0 {
		return fmt.Errorf("metric duration must not be negative")
	}
	r.mu.Lock()
	metric := r.metrics[name]
	metric.Name, metric.Count, metric.Total = name, metric.Count+1, metric.Total+duration
	r.metrics[name] = metric
	r.mu.Unlock()
	return nil
}

// RecordFailure increments the counter for a structured engine-boundary
// failure. Callers own the Registry and choose when a returned error is worth
// recording; 72 does not retain a hidden global error log.
func (r *Registry) RecordFailure(err error) error {
	if err == nil {
		return nil
	}
	var failure *Failure
	if !errors.As(err, &failure) {
		return fmt.Errorf("diagnostic failure must be a *Failure")
	}
	subsystem := string(failure.Subsystem)
	if subsystem == "" {
		subsystem = "engine"
	}
	return r.Add("failure."+subsystem, 1)
}

// Snapshot returns metrics sorted by name.
func (r *Registry) Snapshot() []Metric {
	r.mu.RLock()
	metrics := make([]Metric, 0, len(r.metrics))
	for _, metric := range r.metrics {
		metrics = append(metrics, metric)
	}
	r.mu.RUnlock()
	sort.Slice(metrics, func(left, right int) bool { return metrics[left].Name < metrics[right].Name })
	return metrics
}

// Measure returns a closure that records elapsed wall time when called.
func (r *Registry) Measure(name string) func() {
	started := time.Now()
	return func() { _ = r.Record(name, time.Since(started)) }
}
