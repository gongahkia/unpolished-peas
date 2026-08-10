package bossdsl

import (
	"strings"
	"testing"
)

const validSource = `boss yellow_wind_sage {
  phase opening {
    repeat 3 { telegraph sweep 24; attack sweep; wait 18; }
  }
  phase storm when hp < 50 {
    parallel { spawn tornado 6; move player; }
    wait 30;
  }
}`

func TestParseValidateAndCompile(t *testing.T) {
	file, err := Parse(validSource)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	program, err := Compile(file)
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	if program.BossID != "yellow_wind_sage" || len(program.Phases) != 2 {
		t.Fatalf("unexpected compiled program: %+v", program)
	}
	if program.Phases[0].Code[0].Op != OpRepeat || program.Phases[0].Code[0].Count != 3 {
		t.Fatalf("repeat was not compiled: %+v", program.Phases[0].Code[0])
	}
}

func TestParserReportsSourcePosition(t *testing.T) {
	_, err := Parse("boss x { phase a { wait 2; }")
	if err == nil || !strings.Contains(err.Error(), "1:") {
		t.Fatalf("missing useful parser error: %v", err)
	}
}

func TestValidationRejectsUnknownAndEmptyCommands(t *testing.T) {
	file, err := Parse("boss x { phase a { sparkle now; } }")
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if err := Validate(file); err == nil || !strings.Contains(err.Error(), "unknown command") {
		t.Fatalf("unknown command accepted: %v", err)
	}
	file, err = Parse("boss x { phase a {} }")
	if err != nil {
		t.Fatalf("Parse empty phase: %v", err)
	}
	if err := Validate(file); err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("empty phase accepted: %v", err)
	}
}
