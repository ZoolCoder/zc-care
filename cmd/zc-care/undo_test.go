package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/plan"
)

// oldContent is distinctive so the leak check cannot match a temp path.
const oldContent = "zshrc-7f3a\n"

// journaled records one dotfile apply the way recordApply would: the file was
// oldContent before and the apply replaced it. It returns the data folder and
// the file.
func journaled(t *testing.T) (data, file string) {
	t.Helper()
	return journaledWith(t, true)
}

// journaledRevertible is journaled without the change that keeps no record,
// so undo can put back everything in the entry.
func journaledRevertible(t *testing.T) (data, file string) {
	t.Helper()
	return journaledWith(t, false)
}

func journaledWith(t *testing.T, unrecorded bool) (data, file string) {
	t.Helper()
	data = t.TempDir()
	file = filepath.Join(t.TempDir(), ".zshrc")
	if err := os.WriteFile(file, []byte("new\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	undo := plan.Undo{Provider: "dotfiles", Target: "dots", Resource: ".zshrc", Verb: "restore",
		Data: map[string]string{"path": file, "mode": "600"}, Blob: []byte(oldContent)}
	outcomes := []engine.Outcome{
		{Target: "dots", Resource: ".zshrc", Undo: &undo},
		{Target: "dots", Resource: "failed", Err: errors.New("boom")},
	}
	if unrecorded {
		outcomes = append(outcomes, engine.Outcome{Target: "notes", Resource: "a.txt"})
	}
	if err := saveJournal(data, outcomes, "apply"); err != nil {
		t.Fatal(err)
	}
	return data, file
}

func TestJournalKeepsBlobsPrivateAndOutOfTheEntry(t *testing.T) {
	data, _ := journaled(t)
	entries, err := loadJournal(data, io.Discard)
	if err != nil || len(entries) != 1 {
		t.Fatalf("entries %+v, %v", entries, err)
	}
	// The failed outcome is not recorded; the one with no undo is, as a
	// change that cannot be reversed.
	if got := entries[0].Undos; len(got) != 2 || got[1].Reason == "" {
		t.Fatalf("undos %+v", got)
	}
	blob := entries[0].Undos[0].Data["blob"]
	info, err := os.Stat(blob)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("blob %s: %v %v", blob, info, err)
	}
	raw, _ := os.ReadFile(filepath.Join(journalDir(data), entries[0].ID+".json"))
	if strings.Contains(string(raw), "zshrc-7f3a") || strings.Contains(string(raw), base64.StdEncoding.EncodeToString([]byte(oldContent))) {
		t.Fatalf("content leaked into the entry: %s", raw)
	}
	if info, _ := os.Stat(journalDir(data)); info.Mode().Perm() != 0o700 {
		t.Fatalf("journal dir mode %v", info.Mode().Perm())
	}
}

func TestUndoPlanOnlyChangesNothing(t *testing.T) {
	data, file := journaled(t)
	out, err := run(t, "", "undo", "-data", data, "-plan")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "restore the previous content of "+file) || !strings.Contains(out, "cannot be undone") {
		t.Fatalf("plan:\n%s", out)
	}
	if b, _ := os.ReadFile(file); string(b) != "new\n" {
		t.Fatalf("plan-only changed the file: %q", b)
	}
}

func TestUndoJSONPrintsThePlan(t *testing.T) {
	data, _ := journaled(t)
	out, err := run(t, "", "undo", "-data", data, "-json")
	if err != nil {
		t.Fatal(err)
	}
	var p struct {
		Actions []struct{ Op, Resource string }
	}
	if err := json.Unmarshal([]byte(out), &p); err != nil || len(p.Actions) != 2 {
		t.Fatalf("json %v: %s", err, out)
	}
}

func TestUndoNeedsAYesThenRestoresAndIsNotRepeated(t *testing.T) {
	data, file := journaledRevertible(t)
	if _, err := run(t, "", "undo", "-data", data); !errors.Is(err, errCancelled) {
		t.Fatalf("no answer: %v", err)
	}
	if b, _ := os.ReadFile(file); string(b) != "new\n" {
		t.Fatal("restored without a yes")
	}
	out, err := run(t, "yes\n", "undo", "-data", data)
	if err != nil || !strings.Contains(out, "undone") {
		t.Fatalf("undo: %v\n%s", err, out)
	}
	info, _ := os.Stat(file)
	if b, _ := os.ReadFile(file); string(b) != oldContent || info.Mode().Perm() != 0o600 {
		t.Fatalf("file %q %v", b, info.Mode().Perm())
	}
	if out, _ := run(t, "", "undo", "-data", data); !strings.Contains(out, "nothing to undo") {
		t.Fatalf("second undo: %s", out)
	}
	if out, _ := run(t, "", "undo", "-data", data, "-list"); !strings.Contains(out, "undone") {
		t.Fatalf("list: %s", out)
	}
}

func TestUndoRefusesAnUnknownOrFinishedEntry(t *testing.T) {
	data, _ := journaledRevertible(t)
	if _, err := run(t, "", "undo", "-data", data, "-id", "nope"); err == nil {
		t.Fatal("unknown id accepted")
	}
	entries, _ := loadJournal(data, io.Discard)
	if _, err := run(t, "yes\n", "undo", "-data", data, "-id", entries[0].ID); err != nil {
		t.Fatal(err)
	}
	if _, err := run(t, "", "undo", "-data", data, "-id", entries[0].ID); err == nil {
		t.Fatal("undid an entry twice")
	}
}

func TestUndoWithNothingRecorded(t *testing.T) {
	if out, err := run(t, "", "undo", "-data", t.TempDir()); err != nil || !strings.Contains(out, "nothing to undo") {
		t.Fatalf("%v: %s", err, out)
	}
}

func TestAnUndoIsRecordedInHistoryButNotJournaled(t *testing.T) {
	data, _ := journaledRevertible(t)
	if _, err := run(t, "yes\n", "undo", "-data", data); err != nil {
		t.Fatal(err)
	}
	// The undo logs to the -data folder, and the journal there must not have
	// grown.
	if entries, _ := loadJournal(data, io.Discard); len(entries) != 1 {
		t.Fatalf("undo journaled itself: %+v", entries)
	}
	out, err := run(t, "", "history", "-data", data, "-n", "5")
	if err != nil || !strings.Contains(out, "from undo") {
		t.Fatalf("history %v:\n%s", err, out)
	}
}

func TestRevertOrderIsNewestFirstAndReversedWithinAnEntry(t *testing.T) {
	entries := []journalEntry{
		{ID: "2", Undos: []plan.Undo{{Resource: "c"}, {Resource: "d"}}},
		{ID: "1", Undos: []plan.Undo{{Resource: "a"}, {Resource: "b"}}},
	}
	var got []string
	for _, u := range revertOrder(entries) {
		got = append(got, u.Resource)
	}
	if strings.Join(got, "") != "dcba" {
		t.Fatalf("order %v", got)
	}
}
