package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/plan"
)

const viaUndo = "undo"

// journalEntry is what one apply replaced, kept so undo can put it back. It
// lives beside the activity log, not in it: the log is for people to read,
// and a dotfile's old content may be a secret, so that goes in a 0600 file of
// its own and the entry holds only its path.
type journalEntry struct {
	ID     string      `json:"id"`
	At     time.Time   `json:"at"`
	Via    string      `json:"via"`
	Undone bool        `json:"undone,omitempty"`
	Undos  []plan.Undo `json:"undos"`
	// Reverted holds the indexes of the undos already put back, so an undo
	// that failed half way is not repeated. Older entries lack it.
	Reverted []int `json:"reverted,omitempty"`
}

func journalDir(dataDir string) string { return filepath.Join(dataFolder(dataDir), "undo") }

// saveJournal records the successful outcomes of one apply, and the failed
// ones that kept a partial record. A change that kept no record of what it
// replaced is still listed, so undo can say it cannot reverse it.
func saveJournal(dataDir string, outcomes []engine.Outcome, via string) error {
	var undos []plan.Undo
	for _, o := range outcomes {
		if o.Err != nil && (o.Undo == nil || !o.Undo.Partial) {
			continue
		}
		u := plan.Undo{Target: o.Target, Resource: o.Resource,
			Reason: "this kind of change keeps no record of what it replaced"}
		if o.Undo != nil {
			u = *o.Undo
		}
		if !u.Nothing() {
			undos = append(undos, u)
		}
	}
	if len(undos) == 0 {
		return nil
	}
	now := time.Now()
	e := journalEntry{ID: now.UTC().Format("20060102T150405.000000000"), At: now, Via: via}
	dir := journalDir(dataDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	for n, u := range undos {
		if len(u.Blob) > 0 {
			path := filepath.Join(dir, fmt.Sprintf("%s.%d.blob", e.ID, n))
			if err := os.WriteFile(path, u.Blob, 0o600); err != nil {
				return err
			}
			u.Data = maps.Clone(u.Data)
			u.Data["blob"] = path
		}
		e.Undos = append(e.Undos, u)
	}
	return e.write(dir)
}

func (e journalEntry) write(dir string) error {
	raw, err := json.MarshalIndent(e, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, e.ID+".json"), raw, 0o600)
}

// loadJournal reads every entry, newest first. A file that does not parse is
// skipped with a warning to warn: it is not worth blocking the others.
func loadJournal(dataDir string, warn io.Writer) ([]journalEntry, error) {
	dir := journalDir(dataDir)
	files, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var entries []journalEntry
	for _, f := range files {
		if !strings.HasSuffix(f.Name(), ".json") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, f.Name()))
		var e journalEntry
		if err == nil {
			err = json.Unmarshal(raw, &e)
		}
		if err == nil && e.ID == "" {
			err = errors.New("no id")
		}
		if err != nil {
			fmt.Fprintf(warn, "warning: skipping undo journal file %s: %v\n", f.Name(), err)
			continue
		}
		entries = append(entries, e)
	}
	slices.SortFunc(entries, func(a, b journalEntry) int { return strings.Compare(b.ID, a.ID) })
	return entries, nil
}

// markProgress records which of the entries' undos reverted says were put
// back, marks an entry undone when all its changes are, and returns how many
// changes are still to do.
func markProgress(dataDir string, entries []journalEntry, reverted func(plan.Undo) bool) (int, error) {
	var errs []error
	left := 0
	for _, e := range entries {
		remaining := 0
		for i, u := range e.Undos {
			switch {
			case u.Nothing() || slices.Contains(e.Reverted, i):
			case reverted(u):
				e.Reverted = append(e.Reverted, i)
			default:
				remaining++
			}
		}
		e.Undone = remaining == 0
		left += remaining
		errs = append(errs, e.write(journalDir(dataDir)))
	}
	return left, errors.Join(errs...)
}
