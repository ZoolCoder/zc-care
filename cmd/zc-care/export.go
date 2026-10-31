package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/sh"
)

func init() {
	optional["export"] = runExport
	optional["diff"] = runDiff
	optionalUsage = append(optionalUsage,
		"  "+name+" export   [-o file [-force]] [-config f] [-target t]\n"+
			"                                save what this Mac has, per target, as JSON\n"+
			"  "+name+" diff     [-json] [-exit-code] [-config f] a.json [b.json]\n"+
			"                                what differs between two exports, or one and this Mac\n")
}

// liveSnapshot reads this machine as the config sees it.
func liveSnapshot(ctx context.Context, configPath string, targets []string, stdin io.Reader, stderr io.Writer) (snapshot, error) {
	cfg, err := config.Load(configPath, stdin)
	if err != nil {
		return snapshot{}, err
	}
	eng, err := newEngine(cfg, targets, stdin, stderr)
	if err != nil {
		return snapshot{}, err
	}
	resolved, err := engine.Select(cfg, targets)
	if err != nil {
		return snapshot{}, err
	}
	host, _ := os.Hostname()
	macOS, _ := sh.System().Output(ctx, "sw_vers", "-productVersion")
	s := newSnapshot(eng.Items(ctx), resolved, host, strings.TrimSpace(string(macOS)),
		time.Now().UTC().Format(time.RFC3339))
	s.Config, s.Selection = absConfig(configPath), slices.Clone(targets)
	return s, nil
}

// absConfig is the absolute path of the config file; "" for standard input.
func absConfig(path string) string {
	if path == "-" {
		return ""
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	return abs
}

// liveSide is the config and targets the live side of a diff reads: those the
// snapshot was taken with, unless -config was given. It warns when the config
// is not the snapshot's own.
func liveSide(a snapshot, configFlag string, stderr io.Writer) (string, []string) {
	if configFlag == "" && a.Config != "" {
		return a.Config, a.Selection
	}
	path := findConfig(configFlag)
	if a.Config != "" && absConfig(path) != a.Config {
		fmt.Fprintf(stderr, "warning: snapshot was taken from %s\n", a.Config)
	}
	return path, a.Selection
}

// runExport writes the snapshot of this Mac to stdout, or to the -o file.
func runExport(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := newFlags("export", stderr)
	path := flags.String("config", "", "config file")
	out := flags.String("o", "", "write the snapshot to this file")
	force := flags.Bool("force", false, "overwrite the -o file")
	var targets targetList
	flags.Var(&targets, "target", "limit to this target")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := noOperands("export", flags); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	snap, err := liveSnapshot(ctx, findConfig(*path), targets, stdin, stderr)
	if err != nil {
		return err
	}
	if *out == "" {
		return writeJSON(stdout, snap)
	}
	var buf bytes.Buffer
	if err := writeJSON(&buf, snap); err != nil {
		return err
	}
	if err := writeFile(*out, buf.Bytes(), *force); err != nil {
		return fmt.Errorf("export: %w", err)
	}
	_, err = fmt.Fprintf(stdout, "exported %d target(s) to %s\n", len(snap.Targets), *out)
	return err
}

// runDiff compares two exports, or one export with this Mac.
func runDiff(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := newFlags("diff", stderr)
	path := flags.String("config", "", "config file, for the live side")
	asJSON := flags.Bool("json", false, "machine-readable output")
	exitCode := flags.Bool("exit-code", false, "exit 2 when the snapshots differ")
	if err := flags.Parse(args); err != nil {
		return err
	}
	files := flags.Args()
	if err := rejectTrailingFlags("diff", files); err != nil {
		return err
	}
	if len(files) < 1 || len(files) > 2 {
		return errors.New("diff needs one or two snapshot files, from export")
	}
	a, err := readSnapshot(files[0])
	if err != nil {
		return err
	}
	var b snapshot
	bName := "this Mac"
	if len(files) == 2 {
		bName = files[1]
		b, err = readSnapshot(files[1])
	} else {
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		livePath, liveTargets := liveSide(a, *path, stderr)
		b, err = liveSnapshot(ctx, livePath, liveTargets, stdin, stderr)
	}
	if err != nil {
		return err
	}
	diffs := diffSnapshots(a, b)
	write := func() error { return writeDiff(stdout, a.label("A "+files[0]), b.label("B "+bName), diffs) }
	if *asJSON {
		write = func() error {
			return writeJSON(stdout, struct {
				A       snapshot     `json:"a"`
				B       snapshot     `json:"b"`
				Targets []targetDiff `json:"targets"`
			}{a, b, append([]targetDiff{}, diffs...)})
		}
	}
	if err := write(); err != nil {
		return err
	}
	if *exitCode && len(diffs) > 0 {
		return errDrift
	}
	return nil
}

func readSnapshot(path string) (snapshot, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return snapshot{}, fmt.Errorf("read snapshot: %w", err)
	}
	var s snapshot
	if err := json.Unmarshal(b, &s); err != nil {
		return snapshot{}, fmt.Errorf("%s is not a snapshot from %s export: %w", path, name, err)
	}
	if s.Version != snapshotVersion {
		return snapshot{}, fmt.Errorf("%s is snapshot version %d, this build reads version %d", path, s.Version, snapshotVersion)
	}
	return s, nil
}

// writeDiff prints the differences per target, or says there are none.
func writeDiff(w io.Writer, a, b string, diffs []targetDiff) error {
	var sb strings.Builder
	fmt.Fprintf(&sb, "%s\n%s\n", a, b)
	if len(diffs) == 0 {
		sb.WriteString("\nno differences\n")
	}
	for _, d := range diffs {
		fmt.Fprintf(&sb, "\n%s\n", d.Target)
		for _, e := range d.Errors {
			fmt.Fprintf(&sb, "  error %s\n", e)
		}
		section(&sb, "only in A", d.OnlyA, func(e diffEntry) string { return e.A })
		section(&sb, "only in B", d.OnlyB, func(e diffEntry) string { return e.B })
		section(&sb, "different", d.Different, func(e diffEntry) string { return e.A + " -> " + e.B })
	}
	// The other side can be a snapshot from any Mac.
	_, err := io.WriteString(w, plan.Clean(sb.String()))
	return err
}

func section(sb *strings.Builder, title string, entries []diffEntry, detail func(diffEntry) string) {
	if len(entries) == 0 {
		return
	}
	fmt.Fprintf(sb, "  %s\n", title)
	for _, e := range entries {
		fmt.Fprintf(sb, "    %s  %s\n", e.Item, detail(e))
	}
}
