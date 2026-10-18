package packages

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"
	"sync"

	"github.com/zoolcoder/zc-care/internal/sh"
)

// brew is Homebrew, with mas for App Store apps.
var brew = manager{
	program:   "brew",
	parse:     parseBrewfile,
	installed: brewInstalled,
	details:   brewDetails,
	chosen:    brewChosen,
	outdated:  brewOutdated,
	upgrade:   brewUpgrade,
	key: func(l string) (string, bool) {
		m := brewLine.FindStringSubmatch(l)
		if m == nil {
			return "", false
		}
		return m[1] + ":" + m[2], true
	},
	entry: func(kind, name string) (string, string, error) {
		switch kind {
		case "":
			kind = "brew"
		case "brew", "cask", "tap":
		default:
			return "", "", fmt.Errorf("a Brewfile entry is brew, cask or tap, not %q; add App Store apps by hand, with their id", kind)
		}
		return kind, kind + ` "` + name + `"`, nil
	},
	install: func(r sh.Runner, i item) func(context.Context) error {
		switch i.Kind {
		case "tap":
			// Homebrew loads a third-party tap's formulae only once it is trusted.
			return func(ctx context.Context) error {
				if err := r.Run(ctx, "brew", "tap", i.Name); err != nil {
					return err
				}
				return r.Run(ctx, "brew", "trust", i.Name)
			}
		case "cask":
			return run(r, "brew", "install", "--cask", "--adopt", i.Name)
		case "mas":
			// mas runs sudo itself but drops SUDO_ASKPASS, so without a
			// terminal it cannot ask; under our sudo the dialog works.
			return run(r, "sudo", "mas", "install", i.ID)
		}
		return run(r, "brew", "install", i.Name)
	},
	remove: func(r sh.Runner, i item) func(context.Context) error {
		switch i.Kind {
		case "tap":
			return run(r, "brew", "untap", i.Name)
		case "cask":
			return run(r, "brew", "uninstall", "--cask", i.Name)
		case "mas":
			return run(r, "sudo", "mas", "uninstall", i.ID)
		}
		return run(r, "brew", "uninstall", i.Name)
	},
}

func run(r sh.Runner, name string, args ...string) func(context.Context) error {
	return func(ctx context.Context) error { return r.Run(ctx, name, args...) }
}

func readFile(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read manifest: %w", err)
	}
	return data, nil
}

// brewLine is one Brewfile entry: a kind, a quoted name, and options. Only
// the mas id option matters here.
var (
	brewLine = regexp.MustCompile(`^(\w+)\s+"([^"]+)"(.*)$`)
	masID    = regexp.MustCompile(`id:\s*(\d+)`)
)

// parseBrewfile reads the tap, brew, cask and mas entries of a Brewfile. Any
// other entry (vscode, go, cargo, whalebrew) is returned as unsupported.
func parseBrewfile(data []byte) ([]item, []string, error) {
	var taps, rest []item
	var unsupported []string
	sc := bufio.NewScanner(bytes.NewReader(data))
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		m := brewLine.FindStringSubmatch(line)
		if m == nil {
			return nil, nil, fmt.Errorf("line %d: cannot read %q", n, line)
		}
		i := item{Kind: m[1], Name: m[2]}
		switch i.Kind {
		case "tap":
			taps = append(taps, i)
		case "brew", "cask":
			rest = append(rest, i)
		case "mas":
			id := masID.FindStringSubmatch(m[3])
			if id == nil {
				return nil, nil, fmt.Errorf("line %d: mas %q has no id", n, i.Name)
			}
			i.ID = id[1]
			rest = append(rest, i)
		default:
			unsupported = append(unsupported, i.resource())
		}
	}
	// Taps first, so apply adds a tap before installing from it.
	return append(taps, rest...), unsupported, sc.Err()
}

func brewInstalled(ctx context.Context, r sh.Runner, items []item) (map[string]set, map[string]string, error) {
	have := map[string]set{}
	var (
		mu   sync.Mutex
		errs []error
		wg   sync.WaitGroup
	)
	// Without --full-name brew answers from its shell fast path, not Ruby;
	// set.has matches a tapped package by its short name.
	for kind, args := range map[string][]string{
		"brew": {"list", "--formula", "-1"},
		"cask": {"list", "--cask", "-1"},
		"tap":  {"tap"},
	} {
		wg.Go(func() {
			out, err := r.Output(ctx, "brew", args...)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				errs = append(errs, err)
				return
			}
			have[kind] = newSet(lines(out)...)
		})
	}
	wg.Wait()
	if err := errors.Join(errs...); err != nil {
		return nil, nil, err
	}
	unreadable := map[string]string{}
	if wantsKind(items, "mas") {
		if !r.Has("mas") {
			unreadable["mas"] = "mas is not on PATH; install it (brew install mas) to manage App Store apps"
		} else {
			out, err := r.Output(ctx, "mas", "list")
			if err != nil {
				return nil, nil, err
			}
			ids := set{}
			for _, l := range lines(out) {
				if f := strings.Fields(l); len(f) > 0 {
					ids[f[0]] = true
				}
			}
			have["mas"] = ids
		}
	}
	return have, unreadable, nil
}

func wantsKind(items []item, kind string) bool {
	return slices.ContainsFunc(items, func(i item) bool { return i.Kind == kind })
}
