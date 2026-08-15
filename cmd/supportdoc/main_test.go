package main

import (
	"strings"
	"testing"
)

func TestDecodeLedgerValidatesCompleteEvidenceMetadata(t *testing.T) {
	ledger, err := decodeLedger([]byte(`{
  "schemaVersion": 1,
  "policy": "test policy",
  "targets": [{"id":"linux","label":"Linux","classification":"build-only","requiredEvidence":"runtime matrix"}],
  "claims": [{"id":"linux-build","target":"linux","summary":"build","commit":"0123456789abcdef0123456789abcdef01234567","os":"Fedora 43","gpuDriver":"not observed","browser":"not applicable","testType":"cross-build","date":"2026-08-15"}]
}`))
	if err != nil {
		t.Fatal(err)
	}
	document := string(render(ledger))
	for _, fragment := range []string{"`0123456789abcdef0123456789abcdef01234567`", "Fedora 43", "not observed", "not applicable", "cross-build", "2026-08-15"} {
		if !strings.Contains(document, fragment) {
			t.Fatalf("generated document does not contain %q", fragment)
		}
	}
}

func TestDecodeLedgerRejectsIncompleteClaim(t *testing.T) {
	_, err := decodeLedger([]byte(`{
  "schemaVersion": 1,
  "policy": "test policy",
  "targets": [{"id":"linux","label":"Linux","classification":"build-only","requiredEvidence":"runtime matrix"}],
  "claims": [{"id":"linux-build","target":"linux","summary":"build","commit":"short","os":"Fedora 43","gpuDriver":"","browser":"not applicable","testType":"cross-build","date":"not-a-date"}]
}`))
	if err == nil {
		t.Fatal("decodeLedger accepted incomplete evidence")
	}
}
