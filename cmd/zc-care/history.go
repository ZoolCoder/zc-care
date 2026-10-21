package main

import (
	"flag"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/zoolcoder/toolshell/activity"
	"github.com/zoolcoder/zc-care/internal/engine"
)

// activityLog is the log ZC Care, the CLI and the MCP server share, so
// every apply shows in one place whichever way it ran.
func activityLog(dataDir string) *activity.Log {
	if dataDir == "" {
		dataDir = activity.DataDir(name)
	}
	return &activity.Log{Path: filepath.Join(dataDir, "activity.jsonl")}
}

// recordApply writes one entry per target that ran an action: failed when
// any of its actions failed, naming each with its own error.
func recordApply(outcomes []engine.Outcome, via string) {
	byTarget := map[string][]engine.Outcome{}
	var order []string
	for _, o := range outcomes {
		if _, ok := byTarget[o.Target]; !ok {
			order = append(order, o.Target)
		}
		byTarget[o.Target] = append(byTarget[o.Target], o)
	}
	log := activityLog("")
	for _, t := range order {
		detail, ok := applyDetail(byTarget[t], via)
		_ = log.Append(activity.Entry{At: time.Now(), Kind: "apply", Target: t, Detail: detail, OK: ok})
	}
}

// applyDetail summarises one target's outcomes and reports whether all
// succeeded.
func applyDetail(outcomes []engine.Outcome, via string) (string, bool) {
	var done, failures []string
	for _, o := range outcomes {
		if o.Err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", o.Resource, o.Err))
			continue
		}
		done = append(done, o.Resource)
	}
	if len(failures) == 0 {
		return fmt.Sprintf("%d change(s) applied from %s: %s", len(done), via, short(done, 5)), true
	}
	detail := fmt.Sprintf("%d failed from %s: %s", len(failures), via, strings.Join(failures, "; "))
	if len(done) > 0 {
		detail += fmt.Sprintf(" (%d applied: %s)", len(done), short(done, 5))
	}
	return detail, false
}

// short joins up to n names and counts the rest.
func short(names []string, n int) string {
	if len(names) <= n {
		return strings.Join(names, ", ")
	}
	return fmt.Sprintf("%s and %d more", strings.Join(names[:n], ", "), len(names)-n)
}

func runHistory(args []string, _ io.Reader, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("history", flag.ContinueOnError)
	flags.SetOutput(stderr)
	limit := flags.Int("n", 20, "how many entries")
	asJSON := flags.Bool("json", false, "machine-readable output")
	data := flags.String("data", "", "directory of the activity log")
	if err := flags.Parse(args); err != nil {
		return err
	}
	entries, err := activityLog(*data).Recent(*limit)
	if err != nil {
		return err
	}
	if *asJSON {
		if entries == nil {
			entries = []activity.Entry{}
		}
		return writeJSON(stdout, entries)
	}
	if len(entries) == 0 {
		_, err := fmt.Fprintln(stdout, "nothing recorded yet")
		return err
	}
	tw := tabwriter.NewWriter(stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "WHEN\tKIND\tTARGET\tRESULT\tDETAIL")
	for _, e := range entries {
		result := "ok"
		if !e.OK {
			result = "failed"
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\n", e.At.Local().Format("2006-01-02 15:04"), e.Kind, dash(e.Target), result, e.Detail)
	}
	return tw.Flush()
}
