package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/plan"
)

func TestUndoManualOnlyKeepsEntryOpenAndExits3(t *testing.T) {
	data := t.TempDir()
	outcomes := []engine.Outcome{{Target: "notes", Resource: "a.txt"}}
	if err := saveJournal(data, outcomes, "apply"); err != nil {
		t.Fatal(err)
	}
	out, err := run(t, "", "undo", "-data", data)
	if !errors.Is(err, errManualOnly) || !strings.Contains(out, "stays open") {
		t.Fatalf("undo: %v\n%s", err, out)
	}
	entries, _ := loadJournal(data, io.Discard)
	if len(entries) != 1 || entries[0].Undone {
		t.Fatalf("entry marked undone: %+v", entries)
	}
}

func TestUndoRecordsProgressSoARetrySkipsWhatIsDone(t *testing.T) {
	data, _ := journaledRevertible(t)
	entries, _ := loadJournal(data, io.Discard)
	done := func(u plan.Undo) bool { return u.Resource == ".zshrc" }
	if left, err := markProgress(data, entries, done); err != nil || left != 0 {
		t.Fatalf("progress %d: %v", left, err)
	}
	entries, _ = loadJournal(data, io.Discard)
	if !entries[0].Undone || len(revertOrder(entries)) != 0 {
		t.Fatalf("entry %+v", entries[0])
	}
	partial := journalEntry{ID: "1", Undos: []plan.Undo{{Resource: "a"}, {Resource: "b"}}, Reverted: []int{1}}
	if got := revertOrder([]journalEntry{partial}); len(got) != 1 || got[0].Resource != "a" {
		t.Fatalf("order %+v", got)
	}
}

func TestUndoRejectsIDWithN(t *testing.T) {
	data, _ := journaledRevertible(t)
	if _, err := run(t, "", "undo", "-data", data, "-id", "x", "-n", "2"); err == nil || !strings.Contains(err.Error(), "-id") {
		t.Fatalf("err %v", err)
	}
}

func TestJournalIDsDoNotCollideAndBadFilesWarn(t *testing.T) {
	data := t.TempDir()
	outcomes := []engine.Outcome{{Target: "n", Resource: "a"}}
	for range 3 {
		if err := saveJournal(data, outcomes, "apply"); err != nil {
			t.Fatal(err)
		}
	}
	_ = os.WriteFile(filepath.Join(journalDir(data), "bad.json"), []byte("{"), 0o600)
	var warn strings.Builder
	entries, err := loadJournal(data, &warn)
	if err != nil || len(entries) != 3 || !strings.Contains(warn.String(), "bad.json") {
		t.Fatalf("%d entries, %v, warn %q", len(entries), err, warn.String())
	}
}
