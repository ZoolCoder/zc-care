package main

import (
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"

	"github.com/zoolcoder/zc-care/internal/config"
)

func init() {
	optional["skip"] = runSkip
	optionalUsage = append(optionalUsage,
		"  "+name+" skip     [-undo] [-json] [kind:name...]\n"+
			"                                list or change the packages this machine does not install\n")
}

// runSkip keeps this machine's skip list. With no items it prints the list;
// with items it adds them, or with -undo takes them out. A skipped package
// that is missing is left out of plan, apply and drift; one already
// installed is untouched.
func runSkip(args []string, _ io.Reader, stdout, stderr io.Writer) error {
	flags := newFlags("skip", stderr)
	undo := flags.Bool("undo", false, "take the items off the list")
	asJSON := flags.Bool("json", false, "machine-readable output")
	if err := flags.Parse(args); err != nil {
		return err
	}
	path := config.SkipPath()
	if path == "" {
		return errors.New("no home folder to keep the skip list in")
	}
	list, ignored, err := config.ReadSkip(path)
	if err != nil {
		return err
	}
	config.WarnIgnoredSkips(stderr, ignored)
	items := flags.Args()
	if err := rejectTrailingFlags("skip", items); err != nil {
		return err
	}
	if !*undo {
		if err := checkSkipItems(items); err != nil {
			return err
		}
	}
	if len(items) > 0 {
		if *undo {
			// Undo may name a line that is ignored, so the user can clear it.
			list = slices.DeleteFunc(append(list, ignored...), func(r string) bool { return slices.Contains(items, r) })
		} else {
			list = append(list, ignored...)
			list = append(list, items...)
		}
		if err := config.WriteSkip(path, list); err != nil {
			return err
		}
		if list, _, err = config.ReadSkip(path); err != nil {
			return err
		}
	}
	if *asJSON {
		return writeJSON(stdout, append([]string{}, list...))
	}
	for _, r := range list {
		if _, err := fmt.Fprintln(stdout, r); err != nil {
			return err
		}
	}
	return nil
}

// checkSkipItems refuses an item that is not kind:name with a known kind,
// before anything is written.
func checkSkipItems(items []string) error {
	for _, i := range items {
		if !config.ValidSkipItem(i) {
			return fmt.Errorf("%q is not kind:name with kind one of %s, such as cask:ghostty", i, strings.Join(config.SkipKinds(), ", "))
		}
	}
	return nil
}
