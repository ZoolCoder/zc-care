package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/zoolcoder/toolshell/mcp"
	"github.com/zoolcoder/zc-care/internal/engine"
)

// runUpgrade saves what is outdated, then applies the upgrades. The snapshot
// is what the review skill reads to tell what each tool moved from and to.
func runUpgrade(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("upgrade", flag.ContinueOnError)
	flags.SetOutput(stderr)
	path := flags.String("config", "", "config file")
	yes := flags.Bool("yes", false, "skip the deletion prompt")
	var targets, only targetList
	flags.Var(&targets, "target", "limit to this target")
	flags.Var(&only, "only", "only the change to this resource")
	if err := flags.Parse(args); err != nil {
		return err
	}

	var scope []string
	if *path != "" {
		scope = append(scope, "-config", *path)
	}
	for _, t := range targets {
		scope = append(scope, "-target", t)
	}
	file, err := snapshotOutdated(scope, stdin, stderr)
	if err != nil {
		return err
	}
	if file == "" {
		_, err := fmt.Fprintln(stdout, "nothing is outdated")
		return err
	}
	fmt.Fprintf(stdout, "saved what is outdated to %s\n\n", file)

	apply := append([]string{"apply", "-upgrade"}, scope...)
	for _, o := range only {
		apply = append(apply, "-only", o)
	}
	if *yes {
		apply = append(apply, "-yes")
	}
	return runCLI(apply, stdin, stdout, stderr)
}

// snapshotOutdated writes `list -json -state outdated` to the upgrades folder
// and returns its path, or "" when nothing is outdated.
func snapshotOutdated(scope []string, stdin io.Reader, stderr io.Writer) (string, error) {
	var out bytes.Buffer
	args := append([]string{"list", "-json", "-state", "outdated"}, scope...)
	if err := runCLI(args, stdin, &out, stderr); err != nil {
		return "", err
	}
	var rows []engine.TargetItems
	if err := json.Unmarshal(out.Bytes(), &rows); err != nil {
		return "", fmt.Errorf("read outdated list: %w", err)
	}
	n := 0
	for _, r := range rows {
		n += len(r.Items)
	}
	if n == 0 {
		return "", nil
	}
	dir := filepath.Join(mcp.StateDir(name), "upgrades")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	// The time in the name sorts the files, so the newest is the last update.
	file := filepath.Join(dir, time.Now().Format("2006-01-02T150405")+".json")
	return file, os.WriteFile(file, out.Bytes(), 0o600)
}
