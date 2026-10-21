// Command zc-care sets up a Mac from a YAML file: packages, dotfiles
// through chezmoi, runtimes through mise. plan shows what differs, apply makes it so and verifies, status reads
// what is in place.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"syscall"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/sh"
)

const (
	name      = "zc-care"
	envConfig = "ZC_CARE_CONFIG"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

// command is one subcommand: the same signature as runCLI, so a command is
// testable without a process.
type command func(args []string, stdin io.Reader, stdout, stderr io.Writer) error

// optional holds the commands that live in their own files (ui.go, mcp.go)
// and register themselves, so a project can delete one without editing this
// file. optionalUsage is their lines of the usage text.
var (
	optional      = map[string]command{}
	optionalUsage []string
)

const usageHead = name + ` sets up this Mac from a YAML file: packages, dotfiles
(chezmoi) and runtimes (mise).

Usage:
  ` + name + ` plan     [flags]        show what would change (default)
  ` + name + ` apply    [flags] [file] make the changes; with a saved plan, exactly those
  ` + name + ` status   [flags]        what is in place right now, per target
  ` + name + ` list     [flags]        every package, dotfile and runtime, with versions
  ` + name + ` capture  -target t      write t's manifest from what this machine has
  ` + name + ` validate [flags]        check the config offline
  ` + name + ` doctor   [-json]        health: system, config, programs, targets
  ` + name + ` upgrade  [flags]        save what is outdated, then upgrade it
  ` + name + ` history  [-n 20] [-json] what was applied, newest first
  ` + name + ` drift    [-last] [-json] count what differs from the config, and save it;
                                 -plist prints a launchd agent that runs it daily
`

const usageTail = `  ` + name + ` version

Exit codes:
  0  nothing to do, or the apply converged and was verified
  1  something failed
  2  with -exit-code: changes are outstanding
  3  with -exit-code: nothing left but MANUAL items

Flags:
  -config string   config file, or "-" for standard input; default: $` + envConfig + `,
                   then ./` + name + `.yaml, then ~/.config/` + name + `/` + name + `.yaml
  -target value    limit to this target; repeat for several
  -yes             skip the confirmation prompt for deletions, overwrites of outside
                   edits and scripts
  -exit-code       plan: exit 2 for changes, 3 for manual-only
  -upgrade         plan and apply: also upgrade outdated packages and runtimes
  -only value      plan and apply: only the change to this resource, such as
                   brew:tmux; repeat for several
  -remove item     plan and apply: only uninstall this item, kind:name, and drop it
                   from -target's manifest
  -json            plan, status and list: machine-readable
  -out string      plan: save the plan, to apply exactly what you reviewed;
                   capture: write the manifest to this file, not stdout
  -force           capture: overwrite the -out file
  -state list      list: only these states, comma-separated (missing,outdated,...)
  -kind list       list: only these kinds, comma-separated (brew,cask,dotfile,...)
  -adoc            list: the declared packages and runtimes, with why each is
                   there, as an AsciiDoc page
`

func usage() string {
	return usageHead + strings.Join(optionalUsage, "") + usageTail
}

// -exit-code's signals, not failures: the plan printed fine.
var (
	errDrift      = errors.New("the live state differs from the config")
	errManualOnly = errors.New("only manual items are outstanding")
	errCancelled  = errors.New("cancelled")
)

func main() {
	if runtime.GOOS != "darwin" {
		fmt.Fprintln(os.Stderr, "error: zc-care runs on macOS only")
		os.Exit(1)
	}
	err := runCLI(os.Args[1:], os.Stdin, os.Stdout, os.Stderr)
	switch {
	case err == nil:
	case errors.Is(err, errDrift):
		os.Exit(2)
	case errors.Is(err, errManualOnly):
		os.Exit(3)
	default:
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

type targetList []string

func (t *targetList) String() string { return strings.Join(*t, ",") }
func (t *targetList) Set(v string) error {
	*t = append(*t, v)
	return nil
}

// runCLI is main without the process, so tests drive the CLI as a shell would.
func runCLI(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	cmd := "plan"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "version":
		_, err := fmt.Fprintln(stdout, version)
		return err
	case "help":
		_, err := fmt.Fprint(stdout, usage())
		return err
	case "doctor":
		return runDoctor(args, stdin, stdout, stderr)
	case "upgrade":
		return runUpgrade(args, stdin, stdout, stderr)
	case "history":
		return runHistory(args, stdin, stdout, stderr)
	case "drift":
		return runDrift(args, stdin, stdout, stderr)
	case "plan", "apply", "status", "list", "capture", "validate":
	default:
		if run, ok := optional[cmd]; ok {
			return run(args, stdin, stdout, stderr)
		}
		fmt.Fprint(stderr, usage())
		return fmt.Errorf("unknown command %q", cmd)
	}

	flags := flag.NewFlagSet(cmd, flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() { fmt.Fprint(stderr, usage()) }
	path := flags.String("config", "", "config file")
	yes := flags.Bool("yes", false, "skip the deletion prompt")
	exitCode := flags.Bool("exit-code", false, "exit 2 for changes, 3 for manual-only")
	asJSON := flags.Bool("json", false, "machine-readable output")
	out := flags.String("out", "", "save the plan, or the captured manifest, to this file")
	force := flags.Bool("force", false, "capture: overwrite the -out file")
	states := flags.String("state", "", "list: only these states")
	kinds := flags.String("kind", "", "list: only these kinds")
	adoc := flags.Bool("adoc", false, "list: the declared packages and runtimes as an AsciiDoc page")
	upgrade := flags.Bool("upgrade", false, "also upgrade outdated packages and runtimes")
	// Not in the usage text: the MCP server sets it, so history tells an
	// agent's apply from one typed at a terminal.
	via := flags.String("via", "the terminal", "apply: who asked, for the history")
	remove := flags.String("remove", "", "only uninstall this item, kind:name")
	var targets, only targetList
	flags.Var(&targets, "target", "limit to this target")
	flags.Var(&only, "only", "only the change to this resource")
	if err := flags.Parse(args); err != nil {
		return err
	}
	*path = findConfig(*path)

	cfg, err := config.Load(*path, stdin)
	if err != nil {
		return err
	}
	if cmd == "validate" {
		_, err := fmt.Fprintf(stdout, "%s: %d target(s), valid\n", *path, len(cfg.Targets))
		return err
	}

	// A saved plan is re-planned for the targets it was made for, so a bare
	// `apply file` checks the plan that was reviewed and not a bigger one.
	var saved *plan.Saved
	if file := flags.Arg(0); cmd == "apply" && file != "" {
		s, err := readSavedPlan(file)
		if err != nil {
			return err
		}
		if len(targets) == 0 {
			targets = s.Targets
		} else if !slices.Equal(targets, s.Targets) {
			return fmt.Errorf("this plan was saved for -target %v; apply it with the same selection, or none", s.Targets)
		}
		if len(only) == 0 {
			only = s.Only
		} else if !slices.Equal(only, s.Only) {
			return fmt.Errorf("this plan was saved for -only %v; apply it with the same selection, or none", s.Only)
		}
		if *remove == "" {
			*remove = s.Remove
		} else if *remove != s.Remove {
			return fmt.Errorf("this plan was saved for -remove %q; apply it with the same item, or none", s.Remove)
		}
		*upgrade = *upgrade || s.Upgrade
		saved = &s
	}
	if *upgrade {
		upgradeAll(&cfg)
	}

	// Installers talk through this command's streams, never the process's:
	// under mcp, standard output is the protocol. Their output goes to stderr
	// so -json output stays parseable.
	runner := sh.Exec{Stdin: stdin, Stdout: stderr, Stderr: stderr}
	eng, err := engine.New(cfg, engine.With(runner), targets)
	if err != nil {
		return err
	}
	// Ctrl-C stops apply between actions, so the ones that ran are still logged.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if cmd == "status" {
		return writeStatus(stdout, eng.Status(ctx), *asJSON)
	}
	if cmd == "list" && *adoc {
		return writeAdoc(stdout, eng.Items(ctx))
	}
	if cmd == "list" {
		return writeItems(stdout, filterItems(eng.Items(ctx), *states, *kinds), *asJSON)
	}
	if cmd == "capture" {
		return runCapture(ctx, eng, *out, *force, stdout)
	}

	p, err := planFor(ctx, eng, *remove)
	if err != nil {
		return err
	}
	p = p.Only(only)
	if cmd == "plan" {
		s := p.Snapshot(targets)
		s.Upgrade, s.Only, s.Remove = *upgrade, only, *remove
		return runPlan(p, s, *out, *asJSON, *exitCode, stdout, stderr)
	}

	if saved != nil {
		if err := saved.Matches(p); err != nil {
			return err
		}
	}
	if err := p.Write(stdout); err != nil {
		return err
	}
	if len(p.Executable()) == 0 {
		return nil
	}
	if p.Destructive() && !*yes {
		if *path == "-" {
			return errors.New("this plan deletes things, overwrites outside edits or runs scripts, and the config came from stdin; pass -yes to confirm")
		}
		if !confirm(stdin, stdout) {
			return errCancelled
		}
	}
	fmt.Fprintln(stdout)
	outcomes, err := eng.Apply(ctx, p, stdout)
	recordApply(outcomes, *via)
	return err
}

// planFor is the plan for the config, or with remove set, the one change that
// uninstalls that item.
func planFor(ctx context.Context, eng *engine.Engine, remove string) (plan.Plan, error) {
	if remove == "" {
		return eng.Plan(ctx)
	}
	kind, name, ok := strings.Cut(remove, ":")
	if !ok {
		kind, name = "", remove
	}
	return eng.PlanRemove(kind, name)
}

// upgradeAll makes every target that can upgrade do so, as if its config said
// upgrade: true.
func upgradeAll(cfg *config.Config) {
	for i, t := range cfg.Targets {
		if t.Provider == "packages" || t.Provider == "tools" {
			cfg.Targets[i].Upgrade = true
		}
	}
}

func runPlan(p plan.Plan, saved plan.Saved, out string, asJSON, exitCode bool, stdout, stderr io.Writer) error {
	write := p.Write
	if asJSON {
		write = p.WriteJSON
	}
	if err := write(stdout); err != nil {
		return err
	}
	if out != "" {
		if err := savePlan(saved, out); err != nil {
			return err
		}
		// With -json, stdout is the document; the notice must not break it.
		notice := stdout
		if asJSON {
			notice = stderr
		}
		fmt.Fprintf(notice, "\nsaved to %s; apply it with: %s apply %s\n", out, name, out)
	}
	if exitCode {
		switch {
		case len(p.Executable()) > 0:
			return errDrift
		case len(p.Manual()) > 0:
			return errManualOnly
		}
	}
	return nil
}

func writeStatus(w io.Writer, rows []engine.TargetStatus, asJSON bool) error {
	if asJSON {
		return writeJSON(w, rows)
	}
	width := 0
	for _, r := range rows {
		width = max(width, len(r.Target))
	}
	for _, r := range rows {
		line := r.Summary
		if r.Error != "" {
			line = "error: " + r.Error
		}
		if _, err := fmt.Fprintf(w, "%-*s  %s\n", width, r.Target, line); err != nil {
			return err
		}
	}
	return nil
}

func confirm(stdin io.Reader, stdout io.Writer) bool {
	fmt.Fprint(stdout, "\nthis plan deletes things, overwrites edits made outside the tool or runs scripts. type yes to continue: ")
	var answer string
	if _, err := fmt.Fscanln(stdin, &answer); err != nil {
		return false
	}
	return strings.EqualFold(strings.TrimSpace(answer), "yes")
}

// findConfig picks the config: the flag, the environment, the working
// directory, then the user's config directory.
func findConfig(flagValue string) string {
	if flagValue != "" {
		return flagValue
	}
	if env := os.Getenv(envConfig); env != "" {
		return env
	}
	local := name + ".yaml"
	if _, err := os.Stat(local); err == nil {
		return local
	}
	if dir, err := os.UserConfigDir(); err == nil {
		if home, err := os.UserHomeDir(); err == nil {
			// ~/.config on every platform: a CLI's config belongs where its
			// users look, not in ~/Library on macOS.
			dir = filepath.Join(home, ".config")
		}
		return filepath.Join(dir, name, name+".yaml")
	}
	return local
}

func savePlan(s plan.Saved, path string) error {
	// 0600: a plan names paths and resources, which is nobody else's
	// business on a shared machine.
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("save plan: %w", err)
	}
	defer func() { _ = f.Close() }()
	return s.Write(f)
}

func readSavedPlan(path string) (plan.Saved, error) {
	f, err := os.Open(path)
	if err != nil {
		return plan.Saved{}, fmt.Errorf("read saved plan: %w", err)
	}
	defer func() { _ = f.Close() }()
	return plan.LoadSaved(f)
}
