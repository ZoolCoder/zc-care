package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/toolshell/activity"
)

func TestApplyIsRecordedInHistory(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	if out, _ := run(t, "", "history"); !strings.Contains(out, "nothing recorded yet") {
		t.Fatalf("empty history: %s", out)
	}
	cfg, _ := fixture(t)
	if _, err := run(t, "", "apply", "-config", cfg); err != nil {
		t.Fatal(err)
	}
	out, err := run(t, "", "history")
	if err != nil || !strings.Contains(out, "1 change(s) applied from the terminal: a.txt") || !strings.Contains(out, "notes") {
		t.Fatalf("history: %v\n%s", err, out)
	}
	out, _ = run(t, "", "history", "-json")
	var entries []activity.Entry
	if err := json.Unmarshal([]byte(out), &entries); err != nil || len(entries) != 1 || !entries[0].OK || entries[0].Kind != "apply" {
		t.Fatalf("history -json %v: %s", err, out)
	}
}

func TestUpgradeWithNothingOutdated(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	cfg, _ := fixture(t)
	out, err := run(t, "", "upgrade", "-config", cfg)
	if err != nil || !strings.Contains(out, "nothing is outdated") {
		t.Fatalf("upgrade: %v\n%s", err, out)
	}
	if _, err := os.Stat(filepath.Join(os.Getenv("XDG_STATE_HOME"), name, "upgrades")); !os.IsNotExist(err) {
		t.Fatalf("wrote a snapshot with nothing outdated: %v", err)
	}
}

func TestShortCountsTheRest(t *testing.T) {
	if got := short([]string{"a", "b", "c"}, 2); got != "a, b and 1 more" {
		t.Fatal(got)
	}
}

func TestDriftIsSavedAndLoggedWhenItChanges(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	t.Setenv("PATH", "") // keeps the test from poking a running SketchyBar
	cfg, _ := fixture(t)
	var out bytes.Buffer
	if err := runCLI([]string{"drift", "-config", cfg}, nil, &out, io.Discard); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(out.String(), "1 change(s) outstanding: notes 1;") {
		t.Fatalf("drift: %q", out.String())
	}
	_ = runCLI([]string{"drift", "-config", cfg}, nil, io.Discard, io.Discard)
	out.Reset()
	if err := runCLI([]string{"drift", "-last", "-json"}, nil, &out, io.Discard); err != nil || !strings.Contains(out.String(), `"notes": 1`) {
		t.Fatalf("last %q: %v", out.String(), err)
	}
	out.Reset()
	_ = runCLI([]string{"history", "-json"}, nil, &out, io.Discard)
	if n := strings.Count(out.String(), `"kind": "drift"`); n != 1 {
		t.Fatalf("%d drift entries, want 1 for an unchanged count:\n%s", n, out.String())
	}
	out.Reset()
	if err := runCLI([]string{"drift", "-plist", "-config", cfg, "-hour", "7"}, nil, &out, io.Discard); err != nil ||
		!strings.Contains(out.String(), "<string>"+driftLabel+"</string>") || !strings.Contains(out.String(), "<integer>7</integer>") {
		t.Fatalf("plist %q: %v", out.String(), err)
	}
}
