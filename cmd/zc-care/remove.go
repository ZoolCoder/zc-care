package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/sh"
)

func init() {
	optional["remove"] = runRemove
	optionalUsage = append(optionalUsage,
		"  "+name+" remove   -target t kind:name\n"+
			"                                uninstall an item and drop it from t's manifest; mas:ID for an undeclared app\n")
}

// runRemove uninstalls one item now, since apply only ever adds, and takes
// it out of the manifest so the next plan does not bring it back.
func runRemove(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("remove", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() { fmt.Fprint(stderr, usage()) }
	path := flags.String("config", "", "config file")
	item := flags.String("item", "", "kind:name, such as cask:raycast; or the first argument")
	var targets targetList
	flags.Var(&targets, "target", "the target whose manifest declares the item")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *item == "" {
		*item = flags.Arg(0)
	}
	if *item == "" {
		return errors.New("remove needs an item, such as cask:raycast")
	}
	if *path = findConfig(*path); *path == "-" {
		return errors.New("remove edits a manifest on disk; pass a config file, not standard input")
	}
	cfg, err := config.Load(*path, stdin)
	if err != nil {
		return err
	}
	eng, err := engine.New(cfg, engine.With(sh.Exec{Stdin: stdin, Stdout: stderr, Stderr: stderr}), targets)
	if err != nil {
		return err
	}
	kind, itemName, ok := strings.Cut(*item, ":")
	if !ok {
		kind, itemName = "", *item
	}
	t, err := eng.Remove(context.Background(), kind, itemName)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(stdout, "removed %s and dropped it from %s\n", *item, t.File)
	return err
}
