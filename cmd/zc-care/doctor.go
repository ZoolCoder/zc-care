package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"github.com/zoolcoder/toolshell/doctor"
	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/provider/tools"
	"github.com/zoolcoder/zc-care/internal/security"
	"github.com/zoolcoder/zc-care/internal/sh"
)

// runDoctor checks the install: the binary on PATH, the config, and that
// every target's live state can be read. It also checks security.
func runDoctor(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("doctor", flag.ContinueOnError)
	flags.SetOutput(stderr)
	path := flags.String("config", "", "config file")
	asJSON := flags.Bool("json", false, "machine-readable report")
	fix := flags.Bool("fix", false, "plan the fixes for what doctor found, and apply them after a yes")
	yes := flags.Bool("yes", false, "with -fix: skip the confirmation prompt")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := noOperands("doctor", flags); err != nil {
		return err
	}
	if *fix && *asJSON {
		return errors.New("-fix prints a plan and asks; it cannot also be -json")
	}
	*path = findConfig(*path)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	r := doctor.New(version)
	r.AddCheck(doctor.Binary(name))
	host, _ := os.Hostname()
	r.Add("system", doctor.OK, fmt.Sprintf("%s %s/%s", host, runtime.GOOS, runtime.GOARCH))
	cfg, err := config.Load(*path, stdin)
	r.Err("config", err, fmt.Sprintf("%s, %d target(s)", *path, len(cfg.Targets)))
	if err == nil {
		eng, err := engine.New(cfg, engine.Default(), nil)
		if err != nil {
			r.Add("targets", doctor.Fail, err.Error())
		} else {
			for _, p := range eng.Programs() {
				if path, err := exec.LookPath(p); err != nil {
					r.Add("program "+p, doctor.Fail, "not on PATH")
				} else {
					r.Add("program "+p, doctor.OK, path)
				}
			}
			for _, st := range eng.Status(ctx) {
				switch {
				case st.Error != "":
					r.Add("target "+st.Target, doctor.Fail, st.Error)
				case st.InSync():
					r.Add("target "+st.Target, doctor.OK, st.Summary)
				default:
					r.Add("target "+st.Target, doctor.Warn, st.Summary)
				}
			}
		}
		addShadows(ctx, r, cfg)
	}
	found := security.New(sh.System()).Run(ctx)
	for _, res := range found {
		addSecurity(r, "security ", res)
	}
	// Keys, commits, shell history and AI configs live in the home folder on
	// every system, so these run everywhere.
	user := security.NewUser(sh.System())
	for _, res := range user.Account(ctx) {
		addSecurity(r, "security ", res)
	}
	for _, res := range user.AI() {
		addSecurity(r, "ai ", res)
	}
	// A failed check makes Write return an error, but the fixes are still
	// worth offering.
	reportErr := r.Write(stdout, *asJSON)
	if !*fix {
		return reportErr
	}
	return errors.Join(reportErr, fixFindings(ctx, found, sh.System(), *yes, stdin, stdout, stderr))
}

// addShadows checks that the shell runs each tools target's commands from
// mise, not from a copy earlier on PATH such as Homebrew's. Only a shell
// that activated mise has the PATH to judge: the menu bar app runs doctor
// with a login shell's, which never reads .zshrc.
func addShadows(ctx context.Context, r *doctor.Report, cfg config.Config) {
	runner := sh.System()
	if !runner.Has("mise") || os.Getenv("MISE_SHELL") == "" {
		return
	}
	for _, t := range cfg.Targets {
		if t.Provider != "tools" || !t.For(cfg.Profiles) {
			continue
		}
		shadows, err := tools.Shadowed(ctx, runner, filepath.Dir(cfg.Resolve(t).File), exec.LookPath)
		check := "path " + t.Name
		switch {
		case err != nil:
			r.Add(check, doctor.Warn, "mise bin-paths: "+err.Error())
		case len(shadows) == 0:
			r.Add(check, doctor.OK, "every mise command runs from mise")
		default:
			r.Add(check, doctor.Warn, shadowDetail(shadows))
		}
	}
}

// shadowDetail names the first few shadowed commands and the fix.
func shadowDetail(shadows []tools.Shadow) string {
	var names []string
	for _, s := range shadows[:min(len(shadows), 3)] {
		if s.Got == "" {
			names = append(names, s.Name+" is not on PATH")
		} else {
			names = append(names, s.Name+" runs "+s.Got)
		}
	}
	if more := len(shadows) - len(names); more > 0 {
		names = append(names, fmt.Sprintf("%d more", more))
	}
	return strings.Join(names, ", ") + `; activate mise last in the shell profile, after anything else that adds to PATH, such as eval "$(mise activate zsh)"`
}

// statusUnknown marks a check that could not read its answer. It is not a
// failure, so it never changes doctor's exit code.
const statusUnknown = "unknown"

// addSecurity reports a check. A weak setting is the owner's call, not a
// broken install, so it warns.
func addSecurity(r *doctor.Report, prefix string, res security.Result) {
	status := doctor.Warn
	switch {
	case res.OK:
		status = doctor.OK
	case res.Unknown:
		status = statusUnknown
	}
	r.Add(prefix+res.Name, status, res.Detail)
}

func writeJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
