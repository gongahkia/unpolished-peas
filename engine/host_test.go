package engine

import (
	"fmt"
	"testing"
)

func TestHostContextExposesOnlyOptionalAsyncClipboard(t *testing.T) {
	context := HostContext{Window: &testWindow{}}
	if clipboard, ok := context.AsyncClipboard(); ok || clipboard != nil {
		t.Fatalf("synchronous window unexpectedly exposed async clipboard: %T", clipboard)
	}
	window := &asyncClipboardWindow{}
	context.Window = window
	clipboard, ok := context.AsyncClipboard()
	if !ok || clipboard != window {
		t.Fatalf("async clipboard discovery = %T, %t", clipboard, ok)
	}
	id, err := clipboard.RequestClipboard(ClipboardRequest{Operation: ClipboardWrite, Text: "copied"})
	if err != nil || id != 1 {
		t.Fatalf("clipboard request = %d, %v", id, err)
	}
	if completed := clipboard.PollClipboard(); len(completed) != 1 || completed[0] != (ClipboardCompletion{ID: 1, Operation: ClipboardWrite}) {
		t.Fatalf("clipboard completion = %+v", completed)
	}
	if completed := clipboard.PollClipboard(); len(completed) != 0 {
		t.Fatalf("clipboard completion was not cleared: %+v", completed)
	}
}

type asyncClipboardWindow struct {
	testWindow
	next        ClipboardRequestID
	completions []ClipboardCompletion
}

func (w *asyncClipboardWindow) RequestClipboard(request ClipboardRequest) (ClipboardRequestID, error) {
	if request.Operation != ClipboardRead && request.Operation != ClipboardWrite {
		return 0, fmt.Errorf("unsupported clipboard operation")
	}
	w.next++
	w.completions = append(w.completions, ClipboardCompletion{ID: w.next, Operation: request.Operation})
	return w.next, nil
}

func (w *asyncClipboardWindow) PollClipboard() []ClipboardCompletion {
	result := append([]ClipboardCompletion(nil), w.completions...)
	w.completions = w.completions[:0]
	return result
}
