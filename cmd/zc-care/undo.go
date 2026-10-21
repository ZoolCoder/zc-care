package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"slices"
	"syscall"
	"text/tabwriter"

	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/plan"
)

// runUndo reverts applies: it builds the inverse of what the journal
// recorded as a plan, shows it, and runs it only after the same confirmation
// any destructive plan needs. It needs no config: the journal holds what each
// change replaced.
func runUndo(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := newFlags("undo", stderr)
	count := flags.Int("n", 1, "undo the last N applies")
	id := flags.String("id", "", "undo this journal entry, as `undo -list` shows it")
	list := flags.Bool("list", false, "list what can be undone")
	planOnly := flags.Bool("plan", false, "show what undo would do and change nothing")
	asJSON := flags.Bool("json", false, "machine-readable plan; changes nothing")
	yes := flags.Bool("yes", false, "skip the confirmation prompt")
	data := flags.String("data", "", "directory of the activity log")
	if err := flags.Parse(args); err != nil {
		return err
	}
	entries, err := loadJournal(*data)
	if err != nil {
		return err
	}
	if *list {
		return writeJournal(stdout, entries)
	}
	chosen, err := chooseEntries(entries, *id, *count)
	if err != nil {
		return err
	}
	if len(chosen) == 0 {
		_, err := fmt.Fprintln(stdout, "nothing to undo")
		return err
	}

	p := engine.Revert(engine.With(installerRunner(stdin, stderr)), revertOrder(chosen))
	switch {
	case *asJSON:
		return p.WriteJSON(stdout)
	case *planOnly:
		return writeUndoPlan(stdout, chosen, p)
	}
	return applyUndo(*data, chosen, p, *yes, stdin, stdout)
}

// chooseEntries is the entry with this id, or the newest n that are not
// undone yet.
func chooseEntries(entries []journalEntry, id string, n int) ([]journalEntry, error) {
	if id != "" {
		i := slices.IndexFunc(entries, func(e journalEntry) bool { return e.ID == id })
		switch {
		case i < 0:
			return nil, fmt.Errorf("no journal entry %q; undo -list shows them", id)
		case entries[i].Undone:
			return nil, fmt.Errorf("entry %s is already undone", id)
		}
		return entries[i : i+1], nil
	}
	if n < 1 {
		return nil, errors.New("-n must be at least 1")
	}
	var open []journalEntry
	for _, e := range entries {
		if !e.Undone {
			open = append(open, e)
		}
	}
	return open[:min(n, len(open))], nil
}

// revertOrder is the undo records of entries (newest first), each entry's
// own changes last to first: the later change is put back before the earlier.
func revertOrder(entries []journalEntry) []plan.Undo {
	var out []plan.Undo
	for _, e := range entries {
		for _, u := range slices.Backward(e.Undos) {
			out = append(out, u)
		}
	}
	return out
}

func writeUndoPlan(w io.Writer, chosen []journalEntry, p plan.Plan) error {
	for _, e := range chosen {
		fmt.Fprintf(w, "undoing %s: %d change(s) applied from %s on %s\n", e.ID, len(e.Undos), e.Via, e.At.Local().Format("2006-01-02 15:04"))
	}
	fmt.Fprintln(w)
	if p.Empty() {
		_, err := fmt.Fprintln(w, "nothing to undo")
		return err
	}
	return p.Write(w)
}

func applyUndo(dataDir string, chosen []journalEntry, p plan.Plan, yes bool, stdin io.Reader, stdout io.Writer) error {
	if err := writeUndoPlan(stdout, chosen, p); err != nil {
		return err
	}
	if len(p.Executable()) > 0 {
		if p.Destructive() && !yes && !confirm(stdin, stdout, destructiveWhy) {
			return errCancelled
		}
		fmt.Fprintln(stdout)
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		outcomes, err := engine.Run(ctx, p, stdout)
		recordApply(outcomes, viaUndo)
		if err != nil {
			return err
		}
		fmt.Fprintln(stdout, "undone")
	}
	return markUndone(dataDir, chosen)
}

func writeJournal(w io.Writer, entries []journalEntry) error {
	if len(entries) == 0 {
		_, err := fmt.Fprintln(w, "nothing recorded yet")
		return err
	}
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tWHEN\tVIA\tCHANGES\tSTATE")
	for _, e := range entries {
		state := "can be undone"
		if e.Undone {
			state = "undone"
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%d\t%s\n", e.ID, e.At.Local().Format("2006-01-02 15:04"), e.Via, len(e.Undos), state)
	}
	return tw.Flush()
}
