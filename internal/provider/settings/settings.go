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
	have, typ    string
	state        string
}

func (k key) resource() string { return k.domain + " " + k.name }

// maxReads bounds the defaults processes running at once.
const maxReads = 8

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
	slots := make(chan struct{}, maxReads)
	for i := range keys {
		wg.Go(func() {
			slots <- struct{}{}
			defer func() { <-slots }()
			errs[i] = p.readKey(ctx, &keys[i])
		})
	}
	wg.Wait()
	return keys, errors.Join(errs...)
}

// readKey fills in what the machine holds for k, if anything.
func (p Provider) readKey(ctx context.Context, k *key) error {
	have, typ, present, err := p.current(ctx, k.domain, k.name)
	if err != nil || !present {
		return err
	}
	k.have, k.typ = have, typ
	k.state = provider.Differs
	if same(k.want, have, typ) {
		k.state = provider.InPlace
	}
	return nil
}

// current is the value defaults holds for a key and its type as read-type
// words it; present is false for a key that is not set.
func (p Provider) current(ctx context.Context, domain, name string) (have, typ string, present bool, err error) {
	out, err := p.defaults(ctx, "read", domain, name)
	if err != nil {
		if strings.Contains(err.Error(), "does not exist") {
			return "", "", false, nil
		}
		return "", "", false, err
	}
	kind, err := p.defaults(ctx, "read-type", domain, name)
	if err != nil {
		return "", "", false, err
	}
	return strings.TrimSpace(string(out)), strings.TrimSpace(string(kind)), true, nil
}

// defaults runs a read-only defaults command in the C locale: "does not exist"
// and the type words are matched in English.
func (p Provider) defaults(ctx context.Context, args ...string) ([]byte, error) {
	return p.r.Output(ctx, "env", append([]string{"LC_ALL=C", "defaults"}, args...)...)
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
		unrecordable := overwritesUnrecordable(k)
		if unrecordable {
			detail += "; replaces a value undo cannot restore (" + strings.TrimPrefix(k.typ, "Type is ") + ")"
		}
		actions = append(actions, plan.Action{Op: op, Target: t.Name, Resource: k.resource(), Detail: detail,
			Destructive: unrecordable,
			Before:      func(ctx context.Context) (plan.Undo, error) { return p.before(ctx, k.domain, k.name) },
			Do:          func(ctx context.Context) error { return p.r.Run(ctx, "defaults", args...) }})
		if proc, ok := restarts[k.domain]; ok {
			restart[proc] = true
		}
	}
	for _, proc := range slices.Sorted(maps.Keys(restart)) {
		actions = append(actions, p.restartAction(t.Name, proc))
	}
	return actions, nil
}

// overwritesUnrecordable reports whether the write replaces a value undo
// cannot put back, such as an array or dictionary.
func overwritesUnrecordable(k key) bool {
	if k.state != provider.Differs {
		return false
	}
	_, err := restoreArgs(map[string]string{"domain": k.domain, "key": k.name, "type": k.typ, "value": k.have})
	return err != nil
}

func (p Provider) restartAction(target, proc string) plan.Action {
	return plan.Action{Op: plan.OpUpdate, Target: target, Resource: "restart " + proc,
		Detail: "restart " + proc + " so it reads the new settings",
		Before: func(context.Context) (plan.Undo, error) { return plan.NoUndo(), nil },
		// A process that is not running has nothing to restart.
		Do: func(ctx context.Context) error { _ = p.r.Run(ctx, "killall", proc); return nil }}
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
