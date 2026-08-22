package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const doctorSchemaVersion = 1

type doctorReport struct {
	SchemaVersion int          `json:"schemaVersion"`
	GeneratedAt   time.Time    `json:"generatedAt"`
	GoVersion     string       `json:"goVersion"`
	Target        doctorTarget `json:"target"`
	WebGPU        doctorWebGPU `json:"webgpu"`
	Certification string       `json:"certification"`
}

type doctorTarget struct {
	GOOS   string `json:"goos"`
	GOARCH string `json:"goarch"`
}

type doctorWebGPU struct {
	Status string `json:"status"`
	Probe  string `json:"probe"`
	Error  string `json:"error,omitempty"`
}

func runDoctorWithProbe(arguments []string, stdout, stderr io.Writer, probe func() error) error {
	flags := flag.NewFlagSet("doctor", flag.ContinueOnError)
	flags.SetOutput(stderr)
	output := flags.String("out", "", "required support bundle ZIP path")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("doctor accepts flags only")
	}
	if *output == "" {
		return errors.New("doctor requires -out")
	}
	if probe == nil {
		return errors.New("doctor WebGPU probe must not be nil")
	}
	report := doctorReport{
		SchemaVersion: doctorSchemaVersion,
		GeneratedAt:   time.Now().UTC(),
		GoVersion:     runtime.Version(),
		Target:        doctorTarget{GOOS: runtime.GOOS, GOARCH: runtime.GOARCH},
		WebGPU:        doctorWebGPU{Status: "available", Probe: "headless-fallback"},
		Certification: "unverified",
	}
	if err := probe(); err != nil {
		report.WebGPU.Status = "unavailable"
		report.WebGPU.Error = err.Error()
	}
	encoded, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return fmt.Errorf("encode doctor report: %w", err)
	}
	encoded = append(encoded, '\n')
	if _, err := stdout.Write(encoded); err != nil {
		return fmt.Errorf("write doctor report: %w", err)
	}
	bundle, err := supportBundle(encoded, report)
	if err != nil {
		return err
	}
	if err := writeNewAtomically(*output, bundle); err != nil {
		return err
	}
	return nil
}

func supportBundle(encodedReport []byte, report doctorReport) ([]byte, error) {
	var output bytes.Buffer
	archive := zip.NewWriter(&output)
	entries := []struct {
		name string
		data []byte
	}{
		{name: "report.json", data: encodedReport},
		{name: "go-env.txt", data: []byte(fmt.Sprintf("GOOS=%s\nGOARCH=%s\nGOVERSION=%s\n", report.Target.GOOS, report.Target.GOARCH, report.GoVersion))},
		{name: "README.txt", data: []byte("This bundle records local build diagnostics only. Its certification value is always unverified; a successful WebGPU probe is not target certification.\n")},
	}
	for _, entry := range entries {
		file, err := archive.Create(entry.name)
		if err != nil {
			return nil, fmt.Errorf("create doctor bundle entry %q: %w", entry.name, err)
		}
		if _, err := file.Write(entry.data); err != nil {
			return nil, fmt.Errorf("write doctor bundle entry %q: %w", entry.name, err)
		}
	}
	if err := archive.Close(); err != nil {
		return nil, fmt.Errorf("close doctor support bundle: %w", err)
	}
	return output.Bytes(), nil
}

func writeNewAtomically(path string, data []byte) error {
	if strings.TrimSpace(path) == "" {
		return errors.New("support bundle path must not be empty")
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".72-doctor-*")
	if err != nil {
		return fmt.Errorf("create support bundle output: %w", err)
	}
	temporaryPath := file.Name()
	defer func() { _ = os.Remove(temporaryPath) }()
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		return fmt.Errorf("write support bundle output: %w", err)
	}
	if err := file.Chmod(0o644); err != nil {
		_ = file.Close()
		return fmt.Errorf("set support bundle permissions: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close support bundle output: %w", err)
	}
	if err := os.Link(temporaryPath, path); err != nil {
		if errors.Is(err, os.ErrExist) {
			return fmt.Errorf("support bundle %q already exists", path)
		}
		return fmt.Errorf("publish support bundle %q: %w", path, err)
	}
	return nil
}
