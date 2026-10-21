package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
)

func init() {
	optional["remove"] = runRemove
	optionalUsage = append(optionalUsage,
		"  "+name+" remove   -target t kind:name\n"+
			"                                plan the uninstall of an item, show it and ask; drops it from\n"+
			"                                t's manifest; mas:ID for an undeclared app\n")
}

// runRemove is `apply -remove` for a person at a terminal: the plan is one
// uninstall, shown and confirmed like any plan that deletes. Apply only ever
// adds, so removing is always a request for one named item.
func runRemove(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("remove", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() { fmt.Fprint(stderr, usage()) }
	path := flags.String("config", "", "config file")
	item := flags.String("item", "", "kind:name, such as cask:raycast; or the first argument")
	yes := flags.Bool("yes", false, "skip the confirmation prompt")
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
	apply := []string{"apply", "-config", *path, "-remove", *item}
	for _, t := range targets {
		apply = append(apply, "-target", t)
	}
	if *yes {
		apply = append(apply, "-yes")
	}
	return runCLI(apply, stdin, stdout, stderr)
}
