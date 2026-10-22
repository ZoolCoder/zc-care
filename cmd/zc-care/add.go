package main

import (
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/zoolcoder/zc-care/internal/provider"
)

func init() {
	optional["add"] = runAdd
	optionalUsage = append(optionalUsage,
		"  "+name+" add      -target t -why w [-section s] kind:name\n"+
			"                                declare an item in t's manifest; plan and apply install it\n")
}

// runAdd writes one entry into a target's manifest. It installs nothing, so
// the change is reviewed with plan like any other edit.
func runAdd(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := newFlags("add", stderr)
	path := flags.String("config", "", "config file")
	item := flags.String("item", "", "kind:name, such as cask:raycast or runtime:go@1.26; or the first argument")
	why := flags.String("why", "", "why the item is there, one line; kept as a comment on its line")
	section := flags.String("section", "", "the manifest section to add it under")
	var targets targetList
	flags.Var(&targets, "target", "the target whose manifest gets the item")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := rejectTrailingFlags("add", flags.Args()); err != nil {
		return err
	}
	if *item == "" {
		*item = flags.Arg(0)
	}
	if *item == "" || strings.TrimSpace(*why) == "" {
		return errors.New("add needs an item and -why")
	}
	eng, err := loadManifestEngine("add", findConfig(*path), targets, stdin, stderr)
	if err != nil {
		return err
	}
	kind, itemName, ok := strings.Cut(*item, ":")
	if !ok || strings.Contains(kind, "/") {
		kind, itemName = "", *item
	}
	t, err := eng.Add(provider.Entry{Kind: kind, Name: itemName, Why: *why, Section: *section})
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(stdout, "added %s to %s; review and install it with: %s plan -target %s\n", *item, t.File, name, t.Name)
	return err
}
