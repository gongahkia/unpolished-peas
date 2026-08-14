// Command 72 provides project tooling for the 72 engine.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/gongahkia/72/engine/assets"
)

func main() {
	if err := run(os.Args[1:], os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "72:", err)
		os.Exit(1)
	}
}

func run(arguments []string, stderr io.Writer) error {
	if len(arguments) == 0 {
		return errors.New("expected subcommand; supported: pack")
	}
	switch arguments[0] {
	case "pack":
		return runPack(arguments[1:], stderr)
	default:
		return fmt.Errorf("unsupported subcommand %q; supported: pack", arguments[0])
	}
}

func runPack(arguments []string, stderr io.Writer) error {
	flags := flag.NewFlagSet("pack", flag.ContinueOnError)
	flags.SetOutput(stderr)
	root := flags.String("root", ".", "project root")
	manifestPath := flags.String("manifest", "72.assets.json", "project-relative manifest path")
	output := flags.String("out", "", "output package path")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("pack accepts flags only")
	}
	if *output == "" {
		return errors.New("pack requires -out")
	}
	project := os.DirFS(*root)
	manifest, err := assets.LoadProjectManifest(project, *manifestPath)
	if err != nil {
		return err
	}
	data, err := assets.BuildPackage(project, manifest)
	if err != nil {
		return err
	}
	return writeAtomically(*output, data)
}

func writeAtomically(path string, data []byte) (err error) {
	directory := filepath.Dir(path)
	file, err := os.CreateTemp(directory, ".72-pack-*")
	if err != nil {
		return fmt.Errorf("create package output: %w", err)
	}
	name := file.Name()
	defer func() {
		if err != nil {
			_ = os.Remove(name)
		}
	}()
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		return fmt.Errorf("write package output: %w", err)
	}
	if err := file.Chmod(0o644); err != nil {
		_ = file.Close()
		return fmt.Errorf("set package output permissions: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close package output: %w", err)
	}
	if err := os.Rename(name, path); err != nil {
		return fmt.Errorf("replace package output: %w", err)
	}
	return nil
}
