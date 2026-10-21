// Package settings keeps macOS preferences at the values the config declares:
// the keys `defaults` reads and writes. It never deletes or resets a key: a
// value the config stops declaring stays as it was.
package settings

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"os"
	"path"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
	"github.com/zoolcoder/zc-care/internal/sh"
)

// restarts are the processes that read a domain only when they start, so a
// write shows once they restart.
var restarts = map[string]string{
	"com.apple.dock":          "Dock",
	"com.apple.finder":        "Finder",
	"com.apple.screencapture": "SystemUIServer",
}

type Provider struct {
	r    sh.Runner
	home string
}

func New(r sh.Runner) Provider {
	home, _ := os.UserHomeDir()
	return Provider{r: r, home: home}
}

// key is one declared preference with what the machine holds for it.
type key struct {
	domain, name string
	want         any
	have         string
	state        string
}

func (k key) resource() string { return k.domain + " " + k.name }

// read asks defaults for every key at once: each read is its own process. A
// key that is not set is Missing; any other failure, such as a cancelled
// context, is an error, not a reason to write.
func (p Provider) read(ctx context.Context, t config.Target) ([]key, error) {
	var keys []key
	for _, domain := range slices.Sorted(maps.Keys(t.Defaults)) {
		for _, name := range slices.Sorted(maps.Keys(t.Defaults[domain])) {
			keys = append(keys, key{domain: domain, name: name, want: p.expand(t.Defaults[domain][name]), state: provider.Missing})
		}
	}
	errs := make([]error, len(keys))
	var wg sync.WaitGroup
	for i := range keys {
		wg.Go(func() { errs[i] = p.readKey(ctx, &keys[i]) })
	}
	wg.Wait()
	return keys, errors.Join(errs...)
}

// readKey fills in what the machine holds for k, if anything.
func (p Provider) readKey(ctx context.Context, k *key) error {
	out, err := p.r.Output(ctx, "defaults", "read", k.domain, k.name)
	if err != nil {
		if strings.Contains(err.Error(), "does not exist") {
			return nil
		}
		return err
	}
	k.have = strings.TrimSpace(string(out))
	typ, err := p.r.Output(ctx, "defaults", "read-type", k.domain, k.name)
	if err != nil {
		return err
	}
	k.state = provider.Differs
	if same(k.want, k.have, strings.TrimSpace(string(typ))) {
		k.state = provider.InPlace
	}
	return nil
}

// expand turns a leading ~/ in a string value into the home directory, for
// keys that hold a path.
func (p Provider) expand(v any) any {
	if s, ok := v.(string); ok && strings.HasPrefix(s, "~/") {
		return path.Join(p.home, s[2:])
	}
	return v
}

// same compares a declared value with what `defaults read` prints and
// `read-type` calls its type: 1 or 0 for a bool, and numbers by value, so
// 0.10 matches 0.1. A value of the wrong type is not in place, whatever it
// prints: the string "1" is not the bool true. defaults stores a float in 32
// bits, so 0.15 reads back as 0.1500000059604645.
func same(want any, have, typ string) bool {
	switch w := want.(type) {
	case bool:
		return typ == "Type is boolean" && have == map[bool]string{true: "1", false: "0"}[w]
	case int:
		n, err := strconv.Atoi(have)
		return typ == "Type is integer" && err == nil && n == w
	case float64:
		f, err := strconv.ParseFloat(have, 32)
		return typ == "Type is float" && err == nil && float32(f) == float32(w)
	}
	return typ == "Type is string" && have == fmt.Sprint(want)
}

// writeArgs are the defaults write arguments that store v with its type.
func writeArgs(domain, name string, v any) []string {
	args := []string{"write", domain, name}
	switch w := v.(type) {
	case bool:
		return append(args, "-bool", strconv.FormatBool(w))
	case int:
		return append(args, "-int", strconv.Itoa(w))
	case float64:
		return append(args, "-float", strconv.FormatFloat(w, 'g', -1, 64))
	}
	return append(args, "-string", fmt.Sprint(v))
}

// Plan writes each key that is missing or differs, then restarts the
// processes that read the changed domains.
func (p Provider) Plan(ctx context.Context, t config.Target) ([]plan.Action, error) {
	keys, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	var actions []plan.Action
	restart := map[string]bool{}
	for _, k := range keys {
		op, detail := plan.OpCreate, fmt.Sprintf("set to %v", k.want)
		switch k.state {
		case provider.InPlace:
			continue
		case provider.Differs:
			op, detail = plan.OpUpdate, fmt.Sprintf("%s to %v", k.have, k.want)
		}
		args := writeArgs(k.domain, k.name, k.want)
		actions = append(actions, plan.Action{Op: op, Target: t.Name, Resource: k.resource(), Detail: detail,
			Do: func(ctx context.Context) error { return p.r.Run(ctx, "defaults", args...) }})
		if proc, ok := restarts[k.domain]; ok {
			restart[proc] = true
		}
	}
	for _, proc := range slices.Sorted(maps.Keys(restart)) {
		actions = append(actions, plan.Action{Op: plan.OpUpdate, Target: t.Name, Resource: "restart " + proc,
			Detail: "restart " + proc + " so it reads the new settings",
			// A process that is not running has nothing to restart.
			Do: func(ctx context.Context) error { _ = p.r.Run(ctx, "killall", proc); return nil }})
	}
	return actions, nil
}

func (p Provider) Measure(ctx context.Context, t config.Target) (provider.Live, error) {
	keys, err := p.read(ctx, t)
	if err != nil {
		return provider.Live{}, err
	}
	live := provider.Live{Declared: len(keys)}
	for _, k := range keys {
		if k.state == provider.InPlace {
			live.InPlace++
		}
	}
	live.Summary = fmt.Sprintf("%d of %d settings in place", live.InPlace, live.Declared)
	return live, nil
}

// Items is each declared key, named domain then key.
func (p Provider) Items(ctx context.Context, t config.Target) ([]provider.Item, error) {
	keys, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	items := make([]provider.Item, 0, len(keys))
	for _, k := range keys {
		item := provider.Item{Name: k.resource(), Kind: "setting", State: k.state, Version: k.have, App: k.domain}
		if k.state != provider.InPlace {
			item.Desc = fmt.Sprintf("declared %v", k.want)
		}
		items = append(items, item)
	}
	return items, nil
}

func (Provider) Programs(config.Target) []string { return []string{"defaults", "killall"} }
