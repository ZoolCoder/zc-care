package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The command reference in the manual is the usage text, so the two cannot
// drift. make docs-gen rewrites it.
func TestCommandReferenceMatchesUsage(t *testing.T) {
	path := filepath.Join("..", "..", "docs", "modules", "ROOT", "partials", "usage.adoc")
	want := "// Generated from `" + name + " help` by make docs-gen; do not edit.\n[source,text]\n----\n" + usage() + "----\n"
	if os.Getenv("UPDATE_DOCS") != "" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(want), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	have, err := os.ReadFile(path)
	if err != nil || string(have) != want {
		t.Fatalf("%s is out of date: run make docs-gen", path)
	}
}
