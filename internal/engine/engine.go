// Package engine turns a config plus live state into one plan, applies it,
// and re-plans to verify the apply converged.
package engine

import (
	"context"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"
	"sync"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
	"github.com/zoolcoder/zc-care/internal/provider/agents"
	"github.com/zoolcoder/zc-care/internal/provider/desktop"
	"github.com/zoolcoder/zc-care/internal/provider/dotfiles"
	"github.com/zoolcoder/zc-care/internal/provider/localdir"
	"github.com/zoolcoder/zc-care/internal/provider/packages"
	"github.com/zoolcoder/zc-care/internal/provider/services"
	"github.com/zoolcoder/zc-care/internal/provider/settings"
	"github.com/zoolcoder/zc-care/internal/provider/tools"
	"github.com/zoolcoder/zc-care/internal/sh"
)

// Providers maps a config provider name to its implementation.
type Providers map[string]provider.Provider

// Default is every built-in provider, driving this machine's programs.
func Default() Providers { return With(sh.System()) }

// With is every built-in provider, driving programs through r.
func With(r sh.Runner) Providers {
	return Providers{
		"localdir": localdir.New(),
		"packages": packages.New(r),
		"dotfiles": dotfiles.New(r),
		"tools":    tools.New(r),
		"desktop":  desktop.New(r),
		"settings": settings.New(r),
		"services": services.New(r),
		"agents":   agents.New(r),
	}
}

type Engine struct {
	cfg       config.Config
	providers Providers
	targets   []config.Target
}

// New selects the named targets, or every target when names is empty.
func New(cfg config.Config, providers Providers, names []string) (*Engine, error) {
	targets, err := Select(cfg, names)
	if err != nil {
		return nil, err
	}
	return &Engine{cfg: cfg, providers: providers, targets: targets}, nil
}

// Select returns the named targets with their paths resolved, in config
// order, leaving out those for other profiles than this machine's. An
// unknown name is an error, not an empty plan, and so is a name for
// another profile.
func Select(cfg config.Config, names []string) ([]config.Target, error) {
	for _, n := range names {
		t, ok := cfg.Find(n)
		if !ok {
			return nil, fmt.Errorf("no target named %q in the config", n)
		}
		if !t.For(cfg.Profiles) {
			return nil, fmt.Errorf("target %s is for %s; this machine is %s (zc-care profile changes it)",
				n, strings.Join(t.Profiles, ", "), strings.Join(cfg.Profiles, ", "))
		}
	}
	var out []config.Target
	for _, t := range cfg.Targets {
		if !t.For(cfg.Profiles) {
			continue
		}
		if len(names) == 0 || slices.Contains(names, t.Name) {
			t = cfg.Resolve(t)
			out = append(out, t)
		}
	}
	return out, nil
}

func (e *Engine) provider(t config.Target) (provider.Provider, error) {
	p, ok := e.providers[t.Provider]
	if !ok {
		return nil, fmt.Errorf("target %s: provider %q is not available in this build", t.Name, t.Provider)
	}
	return p, nil
}

// Plan reads live state for every selected target that applies to this
// system.
func (e *Engine) Plan(ctx context.Context) (plan.Plan, error) {
	type result struct {
		actions []plan.Action
		err     error
	}
	results := make([]result, len(e.targets))
	e.each(func(n int, t config.Target) {
		prov, err := e.provider(t)
		if err != nil {
			results[n].err = err
			return
		}
		actions, err := prov.Plan(ctx, t)
		if err != nil {
			err = fmt.Errorf("plan %s: %w", t.Name, err)
		}
		results[n] = result{actions, err}
	})
	var p plan.Plan
	for _, r := range results {
		if r.err != nil {
			return plan.Plan{}, r.err
		}
		p.Add(r.actions...)
	}
	return p, nil
}

// each calls f for every selected target side by side, since targets read
// different programs and files. Results stay in config order through n.
func (e *Engine) each(f func(n int, t config.Target)) {
	var wg sync.WaitGroup
	for n, t := range e.targets {
		wg.Go(func() { f(n, t) })
	}
	wg.Wait()
}

// Outcome is what happened to one action Apply ran: Err is nil when it
// succeeded. Actions Apply never reached, after an interrupt, have none.
type Outcome struct {
	Target, Resource string
	Err              error
	// Undo is what the action replaced, when it can say; nil if it cannot.
	Undo *plan.Undo
}

// ran is what a run of a plan did: the outcomes, the actions that succeeded,
// and the errors of those that did not.
type ran struct {
	outcomes []Outcome
	done     []plan.Action
	errs     []error
	skipped  int
}

// run executes every executable action in order. A failed action is reported
// and the rest still run, so one broken package does not hold up the others.
// A cancelled ctx stops it before the next action.
func run(ctx context.Context, p plan.Plan, w io.Writer) ran {
	var r ran
	var failed []error
	for _, a := range p.Executable() {
		if ctx.Err() != nil {
			r.skipped++
			continue
		}
		undo := before(ctx, a)
		err := a.Do(ctx)
		o := Outcome{Target: a.Target, Resource: a.Resource, Err: err}
		if err == nil {
			o.Undo = undo
		}
		r.outcomes = append(r.outcomes, o)
		if err != nil {
			err = fmt.Errorf("%s %s %s: %w", a.Op, a.Target, a.Resource, err)
			fmt.Fprintf(w, "failed  %v\n", err)
			failed = append(failed, err)
			continue
		}
		r.done = append(r.done, a)
		fmt.Fprintf(w, "done  %s %s %s\n", a.Op, a.Target, a.Resource)
	}
	if len(failed) > 0 {
		r.errs = append(r.errs, fmt.Errorf("%d change(s) failed: %w", len(failed), errors.Join(failed...)))
	}
	if r.skipped > 0 {
		r.errs = append(r.errs, fmt.Errorf("interrupted: %d change(s) not run", r.skipped))
	}
	return r
}

// before reads what a is about to replace. An action that cannot say, or
// whose read failed, still gets a record that names the reason, so undo can
// report it rather than skip it silently.
func before(ctx context.Context, a plan.Action) *plan.Undo {
	if a.Before == nil {
		return nil
	}
	u, err := a.Before(ctx)
	if err != nil {
		u = plan.Irreversible("could not read the previous state: " + err.Error())
	}
	u.Target, u.Resource = a.Target, a.Resource
	return &u
}

// Run executes p without checking it against a config. Undo uses it: a
// reverted change makes the live state differ from the config again, which
// Apply's check would call a failure.
func Run(ctx context.Context, p plan.Plan, w io.Writer) ([]Outcome, error) {
	r := run(ctx, p, w)
	return r.outcomes, errors.Join(r.errs...)
}

// Apply runs p, then re-plans: an action that reported success but left the
// target still different is a failure too. It returns the outcome of each
// action it ran, even on error.
func (e *Engine) Apply(ctx context.Context, p plan.Plan, w io.Writer) ([]Outcome, error) {
	r := run(ctx, p, w)
	errs := r.errs
	if r.skipped == 0 {
		if err := e.verify(ctx, r.done); err != nil {
			errs = append(errs, err)
		}
	}
	if len(errs) > 0 {
		return r.outcomes, errors.Join(errs...)
	}
	_, err := fmt.Fprintln(w, "applied and verified")
	return r.outcomes, err
}

// Revert is the plan that puts back what the recorded undos replaced. Each
// provider turns its own records into actions; a record with a reason, or
// from a provider that cannot revert, becomes a MANUAL line saying why.
func Revert(providers Providers, undos []plan.Undo) plan.Plan {
	var p plan.Plan
	byProvider := map[string][]plan.Undo{}
	var order []string
	for _, u := range undos {
		if u.Nothing() {
			continue
		}
		_, ok := providers[u.Provider].(provider.Reverter)
		if u.Reason != "" || !ok {
			p.Add(plan.Action{Op: plan.OpManual, Target: u.Target, Resource: u.Resource, Detail: cannotUndo(u)})
			continue
		}
		if _, seen := byProvider[u.Provider]; !seen {
			order = append(order, u.Provider)
		}
		byProvider[u.Provider] = append(byProvider[u.Provider], u)
	}
	for _, name := range order {
		p.Add(providers[name].(provider.Reverter).Revert(byProvider[name])...)
	}
	return p
}

func cannotUndo(u plan.Undo) string {
	if u.Reason != "" {
		return "cannot be undone: " + u.Reason
	}
	return "cannot be undone: this kind of change keeps no record of what it replaced"
}

// verify re-plans and reports any of the done actions that is still
// outstanding. Only those are checked: a plan cut down with -only leaves the
// rest outstanding on purpose, and a failed action is already reported.
func (e *Engine) verify(ctx context.Context, done []plan.Action) error {
	if len(done) == 0 {
		return nil
	}
	after, err := e.Plan(ctx)
	if err != nil {
		return fmt.Errorf("verify: %w", err)
	}
	type key struct{ target, resource string }
	applied := make(map[key]bool, len(done))
	for _, a := range done {
		applied[key{a.Target, a.Resource}] = true
	}
	left := 0
	for _, a := range after.Executable() {
		if applied[key{a.Target, a.Resource}] {
			left++
		}
	}
	if left > 0 {
		return fmt.Errorf("applied, but %d change(s) are still outstanding; run plan to see them", left)
	}
	return nil
}

// TargetStatus is one target's live summary. InPlace and Declared are set
// when the provider can count.
type TargetStatus struct {
	Target   string `json:"target"`
	Provider string `json:"provider"`
	Summary  string `json:"summary"`
	InPlace  int    `json:"in_place"`
	Declared int    `json:"declared"`
	Error    string `json:"error,omitempty"`
}

// InSync reports whether everything the target declares is in place.
func (s TargetStatus) InSync() bool {
	return s.Error == "" && s.InPlace == s.Declared
}

// Status summarises every selected target. A target that cannot be read is
// reported in its row rather than failing the others.
func (e *Engine) Status(ctx context.Context) []TargetStatus {
	out := make([]TargetStatus, len(e.targets))
	e.each(func(n int, t config.Target) {
		row := TargetStatus{Target: t.Name, Provider: t.Provider}
		defer func() { out[n] = row }()
		prov, err := e.provider(t)
		if err == nil {
			var live provider.Live
			live, err = prov.Measure(ctx, t)
			row.Summary, row.InPlace, row.Declared = live.Summary, live.InPlace, live.Declared
		}
		if err != nil {
			row.Error = err.Error()
		}
	})
	return out
}

// Programs lists, sorted and once each, the programs the selected targets for
// this system need.
func (e *Engine) Programs() []string {
	var out []string
	for _, t := range e.targets {
		if r, ok := e.providers[t.Provider].(provider.Requirer); ok {
			out = append(out, r.Programs(t)...)
		}
	}
	slices.Sort(out)
	return slices.Compact(out)
}

// Item and its states are re-exported so the CLI reads them through the
// engine, never a provider package.
type Item = provider.Item

const (
	InPlace  = provider.InPlace
	Missing  = provider.Missing
	Differs  = provider.Differs
	Manual   = provider.Manual
	Outdated = provider.Outdated
	Extra    = provider.Extra
	Skipped  = provider.Skipped
)

// TargetItems is one target's inventory: what it declares, item by item.
type TargetItems struct {
	Target   string          `json:"target"`
	Provider string          `json:"provider"`
	Items    []provider.Item `json:"items"`
	Error    string          `json:"error,omitempty"`
}

// Items lists every selected target's items. Like Status, a target that
// cannot be read reports it in its row.
func (e *Engine) Items(ctx context.Context) []TargetItems {
	out := make([]TargetItems, len(e.targets))
	e.each(func(n int, t config.Target) { out[n] = e.items(ctx, t) })
	return dropDeclaredExtras(out)
}

func (e *Engine) items(ctx context.Context, t config.Target) TargetItems {
	row := TargetItems{Target: t.Name, Provider: t.Provider, Items: []provider.Item{}}
	prov, err := e.provider(t)
	if err == nil {
		if l, ok := prov.(provider.Lister); ok {
			row.Items, err = l.Items(ctx, t)
		} else {
			err = fmt.Errorf("provider %s cannot list its items", t.Provider)
		}
	}
	if err != nil {
		row.Error = err.Error()
	}
	return row
}

// dropDeclaredExtras keeps an Extra item only if no target declares it and
// no earlier target already listed it: two Brewfile targets each see the
// other's packages as undeclared.
func dropDeclaredExtras(rows []TargetItems) []TargetItems {
	seen := map[string]bool{}
	for _, r := range rows {
		for _, i := range r.Items {
			if i.State != provider.Extra {
				seen[itemKey(i)] = true
			}
		}
	}
	for n, r := range rows {
		kept := r.Items[:0]
		for _, i := range r.Items {
			if i.State == provider.Extra {
				if seen[itemKey(i)] {
					continue
				}
				seen[itemKey(i)] = true
			}
			kept = append(kept, i)
		}
		rows[n].Items = kept
	}
	return rows
}

// itemKey names an item across targets: its kind and short name, and for a
// runtime its version too, since each version is its own item.
func itemKey(i provider.Item) string {
	name := strings.ToLower(i.Name)
	key := i.Kind + ":" + name[strings.LastIndex(name, "/")+1:]
	if i.Kind == "runtime" {
		key += "@" + i.Version
	}
	return key
}

// single is the one selected target and its provider as a C, for the
// commands that act on exactly one. cannot is the error for a provider that
// is not a C; it may use the provider's name as %[1]s and the target's file
// as %[2]s.
func single[C any](e *Engine, verb, cannot string) (config.Target, C, error) {
	var zero C
	if len(e.targets) != 1 {
		return config.Target{}, zero, fmt.Errorf("%s needs exactly one target, %d selected; use -target", verb, len(e.targets))
	}
	t := e.targets[0]
	prov, err := e.provider(t)
	if err != nil {
		return t, zero, err
	}
	c, ok := prov.(C)
	if !ok {
		return t, zero, fmt.Errorf(cannot, t.Provider, t.File)
	}
	return t, c, nil
}

// Add declares e in the one selected target's manifest.
func (e *Engine) Add(entry provider.Entry) (config.Target, error) {
	t, a, err := single[provider.Adder](e, "add", "provider %[1]s cannot add items; edit %[2]s by hand")
	if err != nil {
		return t, err
	}
	return t, a.Add(t, entry)
}

// PlanRemove is the plan that uninstalls an item and drops it from the one
// selected target's manifest. It changes nothing until the plan is applied.
func (e *Engine) PlanRemove(kind, name string) (plan.Plan, error) {
	t, r, err := single[provider.Remover](e, "remove", "provider %[1]s cannot remove items")
	if err != nil {
		return plan.Plan{}, err
	}
	a, err := r.PlanRemove(t, kind, name)
	return plan.Plan{Actions: []plan.Action{a}}, err
}

// Capture writes the manifest the one selected target would declare to
// match this machine.
func (e *Engine) Capture(ctx context.Context) (config.Target, []byte, error) {
	t, c, err := single[provider.Capturer](e, "capture", "provider %[1]s cannot capture")
	if err != nil {
		return t, nil, err
	}
	data, err := c.Capture(ctx, t)
	return t, data, err
}
