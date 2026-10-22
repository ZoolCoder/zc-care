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
  ` + name + ` doctor   [-json] [-fix] health: system, config, programs, targets; -fix plans
                                 the fixes it can make
  ` + name + ` undo     [-n N | -id id] [-list] [-plan] [-json] [-yes] [-data d]
                                revert the last apply, from what it replaced
  ` + name + ` upgrade  [flags]        save what is outdated, then upgrade it
  ` + name + ` history  [-n 20] [-json] [-data d]
                                what was applied, newest first
  ` + name + ` drift    [-config f] [-json] [-last] [-plist [-hour h]]
                                count what differs from the config, and save it; exit 1 when
                                it cannot plan; -plist prints a launchd agent that runs it daily
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
  -exit-code       plan: exit 2 for changes, 3 for manual-only; diff: exit 2 when the
                   snapshots differ
  -upgrade         plan and apply: also upgrade outdated packages and runtimes
  -only value      plan and apply: only the change to this resource, such as
                   brew:tmux; repeat for several
  -remove item     plan and apply: only uninstall this item, kind:name, and drop it
                   from -target's manifest
  -json            plan, status, list, apply, validate, diff, doctor, history, drift
                   and init: machine-readable; undo: the plan as JSON, changes nothing;
                   capture does not take it
  -out string      plan: save the plan, to apply exactly what you reviewed;
                   capture: write the manifest to this file, not stdout
  -force           capture and export: overwrite the output file
  -o file          export: write the snapshot to this file, not stdout
  -state list      list: only these states, comma-separated (missing,outdated,...)
  -kind list       list: only these kinds, comma-separated (brew,cask,dotfile,...)
  -adoc            list: the declared packages and runtimes, with why each is
                   there, as an AsciiDoc page
  -fix             doctor: plan the fixes it can make, and apply them after a yes
  -n N             undo: revert the last N applies (default 1); history: show N
                   entries (default 20)
  -id id           undo: revert this journal entry, as -list shows it; not with -n
  -list            undo: list what can be undone; init: show the profiles
  -plan            undo: show the reverts and change nothing
  -data dir        undo and history: the folder of the activity log and undo journal
  -item kind:name  add and remove: the item, instead of the first argument
  -last            drift: print the last saved drift, without planning
  -plist           drift: print a launchd agent that runs drift every morning
  -hour N          drift -plist: the hour to run at, 0 to 23 (default 9)
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
	code := exitCode(err)
	if code == 1 {
		fmt.Fprintln(os.Stderr, "error:", err)
	}
	os.Exit(code)
}

// exitCode maps what a command returned to the process's exit code: the
// -exit-code signals get their own, anything else that failed is 1.
func exitCode(err error) int {
	switch {
	case err == nil:
		return 0
	case errors.Is(err, errDrift):
		return 2
	case errors.Is(err, errManualOnly):
		return 3
	}
	return 1
}

type targetList []string

func (t *targetList) String() string { return strings.Join(*t, ",") }
func (t *targetList) Set(v string) error {
	*t = append(*t, v)
	return nil
}

// runCLI is main without the process, so tests drive the CLI as a shell would.
func runCLI(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	err := dispatch(args, stdin, stdout, stderr)
	if errors.Is(err, flag.ErrHelp) {
		return nil
	}
	return err
}

func dispatch(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	cmd := "plan"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, args = args[0], args[1:]
	}
	if cmd == "mcp" && wantsHelp(args) {
		fmt.Fprint(stderr, usage())
		return nil
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
	case "undo":
		return runUndo(args, stdin, stdout, stderr)
	case "plan", "apply", "status", "list", "capture", "validate":
		return runConfigured(cmd, args, stdin, stdout, stderr)
	}
	if run, ok := optional[cmd]; ok {
		return run(args, stdin, stdout, stderr)
	}
	fmt.Fprint(stderr, usage())
	return fmt.Errorf("unknown command %q", cmd)
}

func wantsHelp(args []string) bool {
	return len(args) > 0 && slices.Contains([]string{"-h", "-help", "--help"}, args[0])
}

// cliFlags is every flag the config-driven commands take.
type cliFlags struct {
	path, out, states, kinds, via, remove string
	yes, exitCode, asJSON                 bool
	force, adoc, upgrade                  bool
	targets, only                         targetList
	file                                  string
}

func parseCLIFlags(cmd string, args []string, stderr io.Writer) (cliFlags, error) {
	var f cliFlags
	flags := newFlags(cmd, stderr)
	flags.StringVar(&f.path, "config", "", "config file")
	flags.BoolVar(&f.yes, "yes", false, "skip the deletion prompt")
	flags.BoolVar(&f.exitCode, "exit-code", false, "exit 2 for changes, 3 for manual-only")
	flags.BoolVar(&f.asJSON, "json", false, "machine-readable output")
	flags.StringVar(&f.out, "out", "", "save the plan, or the captured manifest, to this file")
	flags.BoolVar(&f.force, "force", false, "capture: overwrite the -out file")
	flags.StringVar(&f.states, "state", "", "list: only these states")
	flags.StringVar(&f.kinds, "kind", "", "list: only these kinds")
	flags.BoolVar(&f.adoc, "adoc", false, "list: the declared packages and runtimes as an AsciiDoc page")
	flags.BoolVar(&f.upgrade, "upgrade", false, "also upgrade outdated packages and runtimes")
	// Not in the usage text: the MCP server sets it, so history tells an
	// agent's apply from one typed at a terminal.
	flags.StringVar(&f.via, "via", "the terminal", "apply: who asked, for the history")
	flags.StringVar(&f.remove, "remove", "", "only uninstall this item, kind:name")
	flags.Var(&f.targets, "target", "limit to this target")
	flags.Var(&f.only, "only", "only the change to this resource")
	if err := flags.Parse(args); err != nil {
		return f, err
	}
	f.path = findConfig(f.path)
	f.file = flags.Arg(0)
	return f, nil
}

// runConfigured runs a command that reads the config: plan, apply, status,
// list, capture and validate.
func runConfigured(cmd string, args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	f, err := parseCLIFlags(cmd, args, stderr)
	if err != nil {
		return err
	}
	if cmd == "capture" && f.asJSON {
		return errors.New("capture writes a manifest, not JSON; drop -json")
	}
	cfg, err := config.Load(f.path, stdin)
	if cmd == "validate" {
		return runValidate(f, cfg, err, stdout)
	}
	if err != nil {
		return err
	}

	var saved *plan.Saved
	if cmd == "apply" && f.file != "" {
		if saved, err = f.adoptSavedPlan(); err != nil {
			return err
		}
	}
	if f.upgrade {
		upgradeAll(&cfg)
	}

	eng, err := newEngine(cfg, f.targets, stdin, stderr)
	if err != nil {
		return err
	}
	// Ctrl-C stops apply between actions, so the ones that ran are still logged.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	switch cmd {
	case "status":
		return writeStatus(stdout, eng.Status(ctx), f.asJSON)
	case "list":
		if f.adoc {
			return writeAdoc(stdout, eng.Items(ctx))
		}
		return writeItems(stdout, filterItems(eng.Items(ctx), f.states, f.kinds), f.asJSON)
	case "capture":
		return runCapture(ctx, eng, f.out, f.force, stdout)
	}

	p, err := planFor(ctx, eng, f.remove)
	if err != nil {
		return err
	}
	p = p.Only(f.only)
	if cmd == "plan" {
		warnNoProfile(cfg, f.targets, stderr)
		s := p.Snapshot(f.targets)
		s.Upgrade, s.Only, s.Remove = f.upgrade, f.only, f.remove
		return runPlan(p, s, f.out, f.asJSON, f.exitCode, stdout, stderr)
	}
	return runApply(ctx, eng, p, saved, f, stdin, stdout, stderr)
}

// adoptSavedPlan reads the plan file and takes its targets, -only selection
// -remove item and upgrade from it. A saved plan is re-planned for the targets it was
// made for, so a bare `apply file` checks the plan that was reviewed and not
// a bigger one.
func (f *cliFlags) adoptSavedPlan() (*plan.Saved, error) {
	s, err := readSavedPlan(f.file)
	if err != nil {
		return nil, err
	}
	if len(f.targets) == 0 {
		f.targets = s.Targets
	} else if !slices.Equal(f.targets, s.Targets) {
		return nil, fmt.Errorf("this plan was saved for -target %v; apply it with the same selection, or none", s.Targets)
	}
	if len(f.only) == 0 {
		f.only = s.Only
	} else if !slices.Equal(f.only, s.Only) {
		return nil, fmt.Errorf("this plan was saved for -only %v; apply it with the same selection, or none", s.Only)
	}
	if f.remove == "" {
		f.remove = s.Remove
	} else if f.remove != s.Remove {
		return nil, fmt.Errorf("this plan was saved for -remove %q; apply it with the same item, or none", s.Remove)
	}
	f.upgrade = f.upgrade || s.Upgrade
	return &s, nil
}

// runApply shows p, asks before deleting anything, applies it and records
// the run. With -json, stdout carries only the result; the plan and the
// progress go to stderr.
func runApply(ctx context.Context, eng *engine.Engine, p plan.Plan, saved *plan.Saved, f cliFlags, stdin io.Reader, stdout, stderr io.Writer) error {
	if saved != nil {
		if err := saved.Matches(p); err != nil {
			return err
		}
	}
	log := stdout
	if f.asJSON {
		log = stderr
	}
	if err := p.Write(log); err != nil {
		return err
	}
	if len(p.Executable()) == 0 {
		return f.writeApplied(stdout, p, nil, nil)
	}
	if p.Destructive() && !f.yes {
		if f.path == "-" {
			return errors.New("this plan deletes things, overwrites outside edits or runs scripts, and the config came from stdin; pass -yes to confirm")
		}
		if !confirm(stdin, log, destructiveWhy) {
			return errCancelled
		}
	}
	fmt.Fprintln(log)
	apply := eng.Apply
	if saved == nil {
		apply = eng.ApplyFollowing
	}
	outcomes, err := apply(ctx, p, log)
	recordApply("", outcomes, f.via)
	return errors.Join(f.writeApplied(stdout, p, outcomes, err), err)
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

// flagsHeading starts the per-command flag list that -h prints after the usage.
const flagsHeading = "Flags of "

// newFlags is a flag set for a command that reports its errors and usage on
// stderr.
func newFlags(cmd string, stderr io.Writer) *flag.FlagSet {
	flags := flag.NewFlagSet(cmd, flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		fmt.Fprint(stderr, usage())
		fmt.Fprintf(stderr, "\n%s%s:\n", flagsHeading, cmd)
		flags.PrintDefaults()
	}
	return flags
}

// newEngine builds the engine for the named targets. Installers talk through
// this command's streams, never the process's: under mcp, standard output is
// the protocol. Their output goes to stderr so -json output stays parseable.
func newEngine(cfg config.Config, targets []string, stdin io.Reader, stderr io.Writer) (*engine.Engine, error) {
	return engine.New(cfg, engine.With(installerRunner(stdin, stderr)), targets)
}

func installerRunner(stdin io.Reader, stderr io.Writer) sh.Exec {
	return sh.Exec{Stdin: stdin, Stdout: stderr, Stderr: stderr}
}

// loadManifestEngine loads the config and builds the engine for the commands
// that edit a manifest, which needs a file on disk.
func loadManifestEngine(verb, path string, targets []string, stdin io.Reader, stderr io.Writer) (*engine.Engine, error) {
	if path == "-" {
		return nil, fmt.Errorf("%s edits a manifest on disk; pass a config file, not standard input", verb)
	}
	cfg, err := config.Load(path, stdin)
	if err != nil {
		return nil, err
	}
	return newEngine(cfg, targets, stdin, stderr)
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

// warnNoProfile says so when a machine without a profile runs targets that
// are restricted to profiles, since every profile then applies to it.
func warnNoProfile(cfg config.Config, names []string, stderr io.Writer) {
	if len(cfg.Profiles) > 0 {
		return
	}
	restricted := 0
	for _, t := range cfg.Targets {
		if len(t.Profiles) > 0 && (len(names) == 0 || slices.Contains(names, t.Name)) {
			restricted++
		}
	}
	if restricted > 0 {
		fmt.Fprintf(stderr, "no profile set for this Mac: %d target(s) restricted to profiles run anyway; run %s profile NAME\n", restricted, name)
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

const destructiveWhy = "this plan deletes things, overwrites edits made outside the tool or runs scripts"

func confirm(stdin io.Reader, stdout io.Writer, why string) bool {
	fmt.Fprintf(stdout, "\n%s. type yes to continue: ", why)
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
