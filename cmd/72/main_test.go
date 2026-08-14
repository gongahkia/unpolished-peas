package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/gongahkia/72/engine/assets"
)

func TestPackBuildsReadablePackageAtomically(t *testing.T) {
	root := t.TempDir()
	manifest := []byte(`{"version":1,"name":"cli","assets":[{"path":"sound.wav","type":"audio","mode":"external"}]}`)
	if err := os.WriteFile(filepath.Join(root, "72.assets.json"), manifest, 0o644); err != nil {
		t.Fatal(err)
	}
	wav := testWAV()
	if err := os.WriteFile(filepath.Join(root, "sound.wav"), wav, 0o644); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(root, "build", "assets.72.json")
	if err := os.Mkdir(filepath.Dir(output), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"pack", "-root", root, "-out", output}, bytes.NewBuffer(nil)); err != nil {
		t.Fatal(err)
	}
	artifact, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := assets.OpenPackage(bytes.NewReader(artifact), os.DirFS(root))
	if err != nil {
		t.Fatal(err)
	}
	if got, err := reader.ReadAsset("sound.wav"); err != nil || !bytes.Equal(got, wav) {
		t.Fatalf("packed sound = %d bytes, %v", len(got), err)
	}
	if err := run([]string{"pack", "-root", root}, bytes.NewBuffer(nil)); err == nil {
		t.Fatal("pack without output succeeded")
	}
}

func testWAV() []byte {
	data := make([]byte, 46)
	copy(data[0:4], "RIFF")
	data[4] = 38
	copy(data[8:12], "WAVE")
	copy(data[12:16], "fmt ")
	data[16] = 16
	data[20] = 1
	data[22] = 1
	data[24] = 0x80
	data[25] = 0xbb
	data[28] = 0
	data[29] = 0x77
	data[30] = 1
	data[32] = 2
	data[34] = 16
	copy(data[36:40], "data")
	data[40] = 2
	return data
}
