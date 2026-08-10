package assets

import (
	"io"
	"strings"
	"testing"
	"testing/fstest"
)

func stringLoader(_ string, source io.Reader) (string, error) {
	bytes, err := io.ReadAll(source)
	return string(bytes), err
}

func TestManagerLoadsReloadsAndBuildsManifest(t *testing.T) {
	manager := NewManager(fstest.MapFS{"greeting.txt": {Data: []byte("hello")}, "other.txt": {Data: []byte("other")}})
	handle, err := Load(manager, "greeting.txt", stringLoader)
	if err != nil {
		t.Fatal(err)
	}
	if value, ok := Get(manager, handle); !ok || value != "hello" {
		t.Fatalf("loaded asset = %q, %t", value, ok)
	}
	other, err := Load(manager, "other.txt", stringLoader)
	if err != nil {
		t.Fatal(err)
	}
	if err := SetDependencies(manager, handle, other.AssetID()); err != nil {
		t.Fatal(err)
	}
	called := false
	if err := OnReload(manager, handle, func() { called = true }); err != nil {
		t.Fatal(err)
	}
	if err := Reload(manager, handle, func(_ string, _ io.Reader) (string, error) { return "updated", nil }); err != nil {
		t.Fatal(err)
	}
	if value, _ := Get(manager, handle); value != "updated" || !called {
		t.Fatalf("reloaded asset = %q callback=%t", value, called)
	}
	manifest := manager.Manifest()
	if len(manifest) != 2 || manifest[0].Path != "greeting.txt" || len(manifest[0].Dependencies) != 1 {
		t.Fatalf("manifest = %+v", manifest)
	}
	if _, err := Load(manager, "../outside", stringLoader); err == nil || !strings.Contains(err.Error(), "project-relative") {
		t.Fatalf("invalid path error = %v", err)
	}
}
