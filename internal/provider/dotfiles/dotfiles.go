// Package dotfiles applies a chezmoi source directory to the home directory.
// chezmoi does the diffing, templating and per-machine logic; this provider
// turns `chezmoi status` into plan actions and applies one path at a time, so
// apply does exactly what the plan showed.
package dotfiles

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
	"github.com/zoolcoder/zc-care/internal/sh"
)

type Provider struct{ r sh.Runner }

func New(r sh.Runner) Provider { return Provider{r: r} }

// change is one line of `chezmoi status`.
type change struct {
	path string
	// outside is set when the target was edited since chezmoi last wrote it.
	outside bool
	// script is set for a script chezmoi would run, not a file it would write.
	script bool
	op     plan.Op
	what   string
}

var ops = map[byte]struct {
	op   plan.Op
	what string
}{
	'A': {plan.OpCreate, "add"},
	'M': {plan.OpUpdate, "update"},
	'D': {plan.OpDelete, "remove"},
	'R': {plan.OpUpdate, "run script"},
}

// args are the flags that point chezmoi at this target and keep it from
// prompting.
func args(t config.Target, cmd ...string) []string {
	a := []string{"--source", t.Source, "--no-tty"}
	if t.Destination != "" {
		a = append(a, "--destination", t.Destination)
	}
	if t.Mode != "" {
		a = append(a, "--mode", t.Mode)
	}
	return append(a, cmd...)
}

func (p Provider) changes(ctx context.Context, t config.Target) ([]change, error) {
	if err := p.ready(t); err != nil {
		return nil, err
	}
	out, err := p.r.Output(ctx, "chezmoi", args(t, "status", "--exclude", "dirs")...)
	if err != nil {
		return nil, err
	}
	var cs []change
	for l := range strings.SplitSeq(string(out), "\n") {
		if len(l) < 4 {
			continue
		}
		o, ok := ops[l[1]]
		if !ok {
			continue
		}
		cs = append(cs, change{path: l[3:], outside: l[0] != ' ', script: l[1] == 'R', op: o.op, what: o.what})
	}
	return cs, nil
}

// errMissing is a dotfiles target this machine cannot read yet.
type errMissing struct{ msg string }

func (e errMissing) Error() string { return e.msg }

func (p Provider) ready(t config.Target) error {
	if !p.r.Has("chezmoi") {
		return errMissing{"chezmoi is not on PATH; install chezmoi first"}
	}
	if _, err := os.Stat(t.Source); err != nil {
		return errMissing{"source " + t.Source + " is missing; clone the dotfiles repo there"}
	}
	return nil
}

// Plan lists one action per path chezmoi would write, remove or run.
func (p Provider) Plan(ctx context.Context, t config.Target) ([]plan.Action, error) {
	cs, err := p.changes(ctx, t)
	if missing := (errMissing{}); errors.As(err, &missing) {
		return []plan.Action{{Op: plan.OpManual, Target: t.Name, Resource: "chezmoi", Detail: missing.Error()}}, nil
	}
	if err != nil {
		return nil, err
	}
	dest, err := destination(t)
	if err != nil {
		return nil, err
	}
	actions := make([]plan.Action, 0, len(cs))
	for _, c := range cs {
		detail := c.what
		if c.outside {
			detail += "; changed outside chezmoi, apply overwrites it"
		}
		paths := withParents(dest, c.path)
		actions = append(actions, plan.Action{
			Op: c.op, Target: t.Name, Resource: c.path, Detail: detail,
			Destructive: c.outside || c.script,
			Before: func(context.Context) (plan.Undo, error) {
				return before(filepath.Join(dest, c.path), c.script)
			},
			// --force: the plan already showed the overwrite, and without a
			// terminal chezmoi would fail on its own prompt.
			Do: func(ctx context.Context) error {
				return p.r.Run(ctx, "chezmoi", args(t, append([]string{"apply", "--force", "--recursive=false"}, paths...)...)...)
			},
		})
	}
	return actions, nil
}

// managed lists the files and symlinks the source manages, as relative paths.
func (p Provider) managed(ctx context.Context, t config.Target) ([]string, error) {
	out, err := p.r.Output(ctx, "chezmoi", args(t, "managed", "--include", "files,symlinks")...)
	if err != nil {
		return nil, err
	}
	var paths []string
	for l := range strings.SplitSeq(strings.TrimSpace(string(out)), "\n") {
		if l != "" {
			paths = append(paths, l)
		}
	}
	return paths, nil
}

// Measure counts managed files and how many already match the source.
func (p Provider) Measure(ctx context.Context, t config.Target) (provider.Live, error) {
	items, err := p.Items(ctx, t)
	if err != nil {
		return provider.Live{}, err
	}
	var live provider.Live
	scripts := 0
	for _, i := range items {
		switch {
		case i.Kind == "script":
			scripts++
		case i.State == provider.InPlace:
			live.InPlace++
			live.Declared++
		default:
			live.Declared++
		}
	}
	live.Summary = fmt.Sprintf("%d of %d dotfiles in place", live.InPlace, live.Declared)
	if scripts > 0 {
		live.Summary += fmt.Sprintf(", %d script(s) to run", scripts)
	}
	return live, nil
}

// Items lists every managed file with the program it configures, then each
// script chezmoi would run.
func (p Provider) Items(ctx context.Context, t config.Target) ([]provider.Item, error) {
	cs, err := p.changes(ctx, t)
	if err != nil {
		return nil, err
	}
	paths, err := p.managed(ctx, t)
	if err != nil {
		return nil, err
	}
	pending := map[string]change{}
	for _, c := range cs {
		pending[c.path] = c
	}
	items := make([]provider.Item, 0, len(paths))
	for _, path := range paths {
		item := provider.Item{Name: path, Kind: "dotfile", State: provider.InPlace, App: appOf(path)}
		if c, ok := pending[path]; ok {
			item.State = provider.Differs
			if c.op == plan.OpCreate {
				item.State = provider.Missing
			}
			if c.outside {
				item.Desc = "changed outside chezmoi"
			}
			delete(pending, path)
		}
		items = append(items, item)
	}
	for _, c := range cs {
		if _, ok := pending[c.path]; ok {
			items = append(items, provider.Item{Name: c.path, Kind: "script", State: provider.Differs, Desc: c.what})
		}
	}
	return items, nil
}

func destination(t config.Target) (string, error) {
	if t.Destination != "" {
		return t.Destination, nil
	}
	return os.UserHomeDir()
}

// withParents is the absolute path of rel under dest, preceded by each of its
// parent directories: chezmoi applies a file only once its directory exists,
// and --recursive=false keeps it from applying the directories' other files.
func withParents(dest, rel string) []string {
	parts := strings.Split(rel, "/")
	paths := make([]string, len(parts))
	for i := range parts {
		paths[i] = filepath.Join(append([]string{dest}, parts[:i+1]...)...)
	}
	return paths
}

func (Provider) Programs(config.Target) []string { return []string{"chezmoi"} }

// homes are the directories programs keep their config under; the first
// path element below one names the program.
var homes = [][]string{
	{".config"}, {".local", "share"}, {"Library", "Application Support"},
	{"AppData", "Roaming"}, {"AppData", "Local"},
}

// aliases are dotfile names that do not carry their program's name.
var aliases = map[string]string{
	"zprofile": "zsh", "zshenv": "zsh", "zlogin": "zsh", "zlogout": "zsh",
	"profile": "shell", "bash_profile": "bash", "bash_logout": "bash",
	"gitignore": "git", "gitignore_global": "git", "gitattributes": "git",
	"editorconfig": "editorconfig",
}

// appOf names the program a dotfile configures, from where it lives:
// .config/ghostty/config is ghostty, .zshrc is zsh, .gitconfig is git.
func appOf(path string) string {
	parts := strings.Split(path, "/")
	// A login item configures launchd itself, whatever job it runs.
	if len(parts) > 2 && parts[0] == "Library" && parts[1] == "LaunchAgents" {
		return "launchd"
	}
	for _, home := range homes {
		if len(parts) > len(home) && slices.Equal(parts[:len(home)], home) {
			name, _, _ := strings.Cut(parts[len(home)], ".")
			return name
		}
	}
	name, _, _ := strings.Cut(strings.TrimPrefix(parts[0], "."), ".")
	if app, ok := aliases[name]; ok {
		return app
	}
	for _, suffix := range []string{"rc", "config"} {
		if trimmed := strings.TrimSuffix(name, suffix); trimmed != name && trimmed != "" {
			return trimmed
		}
	}
	return name
}
