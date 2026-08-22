package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"go/parser"
	"go/token"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
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

func TestNewCreatesACompleteStarterWithoutOverwriting(t *testing.T) {
	destination := filepath.Join(t.TempDir(), "starter")
	var output bytes.Buffer
	if err := runWithOutput([]string{"new", "-module", "example.com/me/starter", destination}, &output, io.Discard); err != nil {
		t.Fatalf("new starter: %v", err)
	}
	if !strings.Contains(output.String(), "example.com/me/starter") {
		t.Fatalf("new output = %q", output.String())
	}
	for _, path := range []string{"go.mod", "main.go", "main_test.go", "72.assets.json", "Makefile", "web/index.html", "assets/player.png", ".gitignore", "README.md"} {
		if _, err := os.Stat(filepath.Join(destination, path)); err != nil {
			t.Fatalf("starter file %q: %v", path, err)
		}
	}
	for _, path := range []string{"main.go", "main_test.go"} {
		if _, err := parser.ParseFile(token.NewFileSet(), filepath.Join(destination, path), nil, parser.AllErrors); err != nil {
			t.Fatalf("parse generated %s: %v", path, err)
		}
	}
	manifest, err := assets.LoadProjectManifest(os.DirFS(destination), "72.assets.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := assets.BuildPackage(os.DirFS(destination), manifest); err != nil {
		t.Fatalf("build generated package: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(destination, "go.mod"))
	if err != nil || !strings.Contains(string(data), "module example.com/me/starter") || !strings.Contains(string(data), "github.com/gongahkia/72 v0.1.0") {
		t.Fatalf("generated go.mod = %q, %v", data, err)
	}
	if err := runWithOutput([]string{"new", "-module", "example.com/me/starter", destination}, io.Discard, io.Discard); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("overwrite error = %v", err)
	}
}

func TestNewRejectsInvalidModuleAndDestination(t *testing.T) {
	for _, arguments := range [][]string{
		{"new", filepath.Join(t.TempDir(), "game")},
		{"new", "-module", "../outside", filepath.Join(t.TempDir(), "game")},
		{"new", "-module", "example.com/game"},
	} {
		if err := runWithOutput(arguments, io.Discard, io.Discard); err == nil {
			t.Fatalf("new %v succeeded", arguments)
		}
	}
}

func TestDoctorReportsUnavailableProbeAndWritesRedactedBundle(t *testing.T) {
	output := filepath.Join(t.TempDir(), "support.zip")
	var reportOutput bytes.Buffer
	probeErr := errors.New("no adapter")
	if err := runDoctorWithProbe([]string{"-out", output}, &reportOutput, io.Discard, func() error { return probeErr }); err != nil {
		t.Fatal(err)
	}
	var report doctorReport
	if err := json.Unmarshal(reportOutput.Bytes(), &report); err != nil {
		t.Fatal(err)
	}
	if report.SchemaVersion != doctorSchemaVersion || report.Certification != "unverified" || report.WebGPU.Status != "unavailable" || report.WebGPU.Error != probeErr.Error() {
		t.Fatalf("doctor report = %+v", report)
	}
	archive, err := zip.OpenReader(output)
	if err != nil {
		t.Fatal(err)
	}
	defer archive.Close()
	names := make([]string, 0, len(archive.File))
	for _, file := range archive.File {
		names = append(names, file.Name)
	}
	sort.Strings(names)
	if want := []string{"README.txt", "go-env.txt", "report.json"}; !equalStrings(names, want) {
		t.Fatalf("support bundle entries = %v, want %v", names, want)
	}
	if err := runDoctorWithProbe([]string{"-out", output}, io.Discard, io.Discard, func() error { return nil }); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("doctor overwrite error = %v", err)
	}
}

func TestDoctorRejectsMissingOutput(t *testing.T) {
	if err := runDoctorWithProbe(nil, io.Discard, io.Discard, func() error { return nil }); err == nil || !strings.Contains(err.Error(), "requires -out") {
		t.Fatalf("doctor missing output error = %v", err)
	}
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
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
