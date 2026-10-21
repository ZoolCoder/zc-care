package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/sh"
)

func init() {
	optional["export"] = runExport
	optional["diff"] = runDiff
	optionalUsage = append(optionalUsage,
		"  "+name+" export   [-o file] [-config f] [-target t]\n"+
			"                                save what this Mac has, per target, as JSON\n"+
			"  "+name+" diff     [-json] a.json [b.json]\n"+
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
	return newSnapshot(eng.Items(ctx), resolved, host, strings.TrimSpace(string(macOS)),
		time.Now().UTC().Format(time.RFC3339)), nil
}

// runExport writes the snapshot of this Mac to stdout, or to the -o file.
func runExport(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := newFlags("export", stderr)
	path := flags.String("config", "", "config file")
	out := flags.String("o", "", "write the snapshot to this file")
	var targets targetList
	flags.Var(&targets, "target", "limit to this target")
	if err := flags.Parse(args); err != nil {
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
	// 0600: a snapshot names every package and file on the Mac.
	f, err := os.OpenFile(*out, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("export: %w", err)
	}
	if err := errors.Join(writeJSON(f, snap), f.Close()); err != nil {
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
	if err := flags.Parse(args); err != nil {
		return err
	}
	files := flags.Args()
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
		b, err = liveSnapshot(ctx, findConfig(*path), nil, stdin, stderr)
	}
	if err != nil {
		return err
	}
	diffs := diffSnapshots(a, b)
	if *asJSON {
		return writeJSON(stdout, struct {
			A       snapshot     `json:"a"`
			B       snapshot     `json:"b"`
			Targets []targetDiff `json:"targets"`
		}{a, b, append([]targetDiff{}, diffs...)})
	}
	return writeDiff(stdout, a.label("A "+files[0]), b.label("B "+bName), diffs)
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
	_, err := io.WriteString(w, sb.String())
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
