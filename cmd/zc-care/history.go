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
	"github.com/zoolcoder/zc-care/internal/plan"
)

// activityLog is the log ZC Care, the CLI and the MCP server share, so
// every apply shows in one place whichever way it ran.
func activityLog(dataDir string) *activity.Log {
	if dataDir == "" {
		dataDir = activity.DataDir(name)
	}
	return &activity.Log{Path: filepath.Join(dataDir, "activity.jsonl")}
}

// recordApply writes one entry per target the plan touched.
func recordApply(p plan.Plan, via string, applyErr error) {
	byTarget := map[string][]string{}
	var order []string
	for _, a := range p.Executable() {
		if _, ok := byTarget[a.Target]; !ok {
			order = append(order, a.Target)
		}
		byTarget[a.Target] = append(byTarget[a.Target], a.Resource)
	}
	log := activityLog("")
	for _, t := range order {
		res := byTarget[t]
		detail := fmt.Sprintf("%d change(s) applied from %s: %s", len(res), via, short(res, 5))
		if applyErr != nil {
			detail = fmt.Sprintf("from %s: %v", via, applyErr)
		}
		_ = log.Append(activity.Entry{At: time.Now(), Kind: "apply", Target: t, Detail: detail, OK: applyErr == nil})
	}
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
