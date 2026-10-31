package main

import (
	"context"
	"errors"
	"flag"
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
	asJSON := flags.Bool("json", false, "the plan as JSON, whether or not -plan is given; changes nothing")
	yes := flags.Bool("yes", false, "skip the confirmation prompt")
	data := flags.String("data", "", "folder of the activity log and the undo journal")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := noOperands("undo", flags); err != nil {
		return err
	}
	if *id != "" && flagGiven(flags, "n") {
		return errors.New("use -n or -id, not both")
	}
	entries, err := loadJournal(*data, stderr)
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
	return applyUndo(*data, chosen, p, *yes, stdin, stdout, stderr)
}

func flagGiven(flags *flag.FlagSet, name string) bool {
	given := false
	flags.Visit(func(f *flag.Flag) { given = given || f.Name == name })
	return given
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

// pendingUndo is one undo record still to put back, with where it sits.
type pendingUndo struct {
	entry string
	index int
	undo  plan.Undo
}

// pendingUndos is the undo records of entries (newest first) not yet put back,
// each entry's own changes last to first: the later change is put back before
// the earlier.
func pendingUndos(entries []journalEntry) []pendingUndo {
	var out []pendingUndo
	for _, e := range entries {
		for i, u := range slices.Backward(e.Undos) {
			if !slices.Contains(e.Reverted, i) {
				out = append(out, pendingUndo{e.ID, i, u})
			}
		}
	}
	return out
}

func revertOrder(entries []journalEntry) []plan.Undo {
	var out []plan.Undo
	for _, p := range pendingUndos(entries) {
		out = append(out, p.undo)
	}
	return out
}

func writeUndoPlan(w io.Writer, chosen []journalEntry, p plan.Plan) error {
	for _, e := range chosen {
		fmt.Fprintf(w, "undoing %s: %d change(s) applied from %s on %s\n", e.ID, len(e.Undos), plan.Plain(e.Via), e.At.Local().Format("2006-01-02 15:04"))
	}
	fmt.Fprintln(w)
	if p.Empty() {
		_, err := fmt.Fprintln(w, "nothing to undo")
		return err
	}
	return p.Write(w)
}

// applyUndo runs the reverts of p and records which undos it put back, so a
// retry after a failure skips them. An entry is undone only when every one of
// its changes is; one with changes that need a person stays open and exits 3.
func applyUndo(dataDir string, chosen []journalEntry, p plan.Plan, yes bool, stdin io.Reader, stdout, stderr io.Writer) error {
	if err := writeUndoPlan(stdout, chosen, p); err != nil {
		return err
	}
	var outcomes []engine.Outcome
	var runErr error
	if len(p.Executable()) > 0 {
		if p.Destructive() && !yes && !confirm(stdin, stdout, destructiveWhy) {
			return errCancelled
		}
		fmt.Fprintln(stdout)
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		outcomes, runErr = engine.Run(ctx, p, stdout)
		recordApply(dataDir, outcomes, viaUndo, stderr)
	}
	left, acked, saveErr := markProgress(dataDir, chosen, revertedBy(chosen, p, outcomes, runErr))
	if err := errors.Join(runErr, saveErr); err != nil {
		return err
	}
	switch {
	case left > 0:
		fmt.Fprintf(stdout, "%d change(s) must be put back by hand; the entry stays open\n", left)
		return errManualOnly
	case acked > 0:
		fmt.Fprintf(stdout, "%d change(s) cannot be undone and are left to you; the entry is closed\n", acked)
		return errManualOnly
	}
	if len(p.Executable()) > 0 {
		fmt.Fprintln(stdout, "undone")
	}
	return nil
}

// revertedBy says whether the undo at index i of entry id was put back by the
// run of p. Revert gives each undo at most one action and keeps their order,
// so the undos of one target and resource take that resource's outcomes (and
// MANUAL lines) in turn. After a clean run an undo with no outcome was left
// to a person; after a failed one only those with a successful outcome count.
func revertedBy(chosen []journalEntry, p plan.Plan, outcomes []engine.Outcome, runErr error) func(id string, i int) bool {
	key := func(target, resource string) string { return target + "\x00" + resource }
	manual, done := map[string]int{}, map[string][]bool{}
	for _, a := range p.Manual() {
		manual[key(a.Target, a.Resource)]++
	}
	for _, o := range outcomes {
		k := key(o.Target, o.Resource)
		done[k] = append(done[k], o.Err == nil)
	}
	result := map[string]bool{}
	for _, pu := range pendingUndos(chosen) {
		if pu.undo.Nothing() {
			continue
		}
		k := key(pu.undo.Target, pu.undo.Resource)
		ok := false
		switch {
		case pu.undo.Reason != "":
			manual[k]--
		case len(done[k]) > 0:
			ok, done[k] = done[k][0], done[k][1:]
		case manual[k] > 0:
			manual[k]--
		default:
			ok = runErr == nil
		}
		result[fmt.Sprintf("%s#%d", pu.entry, pu.index)] = ok
	}
	return func(id string, i int) bool { return result[fmt.Sprintf("%s#%d", id, i)] }
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
		fmt.Fprintf(tw, "%s\t%s\t%s\t%d\t%s\n", e.ID, e.At.Local().Format("2006-01-02 15:04"), plan.Plain(e.Via), len(e.Undos), state)
	}
	return tw.Flush()
}
