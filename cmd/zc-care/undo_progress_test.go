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

func TestUndoManualOnlyIsReportedOnceThenCloses(t *testing.T) {
	data := t.TempDir()
	outcomes := []engine.Outcome{{Target: "notes", Resource: "a.txt"}}
	if err := saveJournal(data, outcomes, "apply"); err != nil {
		t.Fatal(err)
	}
	out, err := run(t, "", "undo", "-data", data)
	if !errors.Is(err, errManualOnly) || !strings.Contains(out, "cannot be undone") {
		t.Fatalf("undo: %v\n%s", err, out)
	}
	entries, _ := loadJournal(data, io.Discard)
	if len(entries) != 1 || !entries[0].Undone {
		t.Fatalf("entry still open: %+v", entries)
	}
	out, err = run(t, "", "undo", "-data", data)
	if err != nil || !strings.Contains(out, "nothing to undo") {
		t.Fatalf("second undo: %v\n%s", err, out)
	}
}

func TestUndoJSONDoesNotAcknowledgeManualUndos(t *testing.T) {
	data := t.TempDir()
	if err := saveJournal(data, []engine.Outcome{{Target: "notes", Resource: "a.txt"}}, "apply"); err != nil {
		t.Fatal(err)
	}
	if _, err := run(t, "", "undo", "-data", data, "-json"); err != nil {
		t.Fatal(err)
	}
	entries, _ := loadJournal(data, io.Discard)
	if entries[0].Undone || len(entries[0].Reverted) != 0 {
		t.Fatalf("json mutated %+v", entries[0])
	}
}

func TestRevertedByMatchesEachUndoToItsOwnOutcome(t *testing.T) {
	u := plan.Undo{Provider: "packages", Target: "pk", Resource: "brew:x", Verb: "install"}
	chosen := []journalEntry{{ID: "new", Undos: []plan.Undo{u}}, {ID: "old", Undos: []plan.Undo{u}}}
	var p plan.Plan
	outcomes := []engine.Outcome{
		{Target: "pk", Resource: "brew:x"},
		{Target: "pk", Resource: "brew:x", Err: errors.New("boom")},
	}
	reverted := revertedBy(chosen, p, outcomes, errors.New("1 change(s) failed"))
	if !reverted("new", 0) || reverted("old", 0) {
		t.Fatalf("new=%v old=%v", reverted("new", 0), reverted("old", 0))
	}
}

func TestUndoRecordsProgressSoARetrySkipsWhatIsDone(t *testing.T) {
	data, _ := journaledRevertible(t)
	entries, _ := loadJournal(data, io.Discard)
	done := func(string, int) bool { return true }
	if left, _, err := markProgress(data, entries, done); err != nil || left != 0 {
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
