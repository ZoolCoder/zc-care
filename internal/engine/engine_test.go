package engine

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
)

// stuck accepts every write and changes nothing, so verify must catch it.
type stuck struct{}

func (stuck) Plan(context.Context, config.Target) ([]plan.Action, error) {
	return []plan.Action{{Op: plan.OpCreate, Target: "t", Resource: "r",
		Do: func(context.Context) error { return nil }}}, nil
}
func (stuck) Measure(context.Context, config.Target) (provider.Live, error) {
	return provider.Live{Summary: "stuck"}, nil
}

func cfg(dir string) config.Config {
	return config.Config{Version: 1, Dir: dir, Targets: []config.Target{
		{Name: "a", Provider: "localdir", Path: "a", Files: map[string]string{"x": "1"}},
		{Name: "b", Provider: "localdir", Path: "b", Files: map[string]string{"y": "2"}},
	}}
}

func TestPlanApplyVerify(t *testing.T) {
	ctx := context.Background()
	e, err := New(cfg(t.TempDir()), Default(), []string{"b"})
	if err != nil {
		t.Fatal(err)
	}
	p, err := e.Plan(ctx)
	if err != nil || len(p.Actions) != 1 || p.Actions[0].Target != "b" {
		t.Fatalf("plan %+v %v", p, err)
	}
	var out bytes.Buffer
	if _, err := e.Apply(ctx, p, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "applied and verified") {
		t.Fatalf("out %q", out.String())
	}
	if st := e.Status(ctx); len(st) != 1 || !strings.HasPrefix(st[0].Summary, "1 of 1") {
		t.Fatalf("status %+v", st)
	}
}

func TestApplyCatchesAWriteThatDidNothing(t *testing.T) {
	ctx := context.Background()
	c := cfg(t.TempDir())
	c.Targets[0].Provider = "stuck"
	e, _ := New(c, Providers{"stuck": stuck{}}, []string{"a"})
	p, _ := e.Plan(ctx)
	if _, err := e.Apply(ctx, p, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "still outstanding") {
		t.Fatalf("apply %v", err)
	}
}

func TestApplyKeepsGoingPastAFailure(t *testing.T) {
	ctx := context.Background()
	e, _ := New(cfg(t.TempDir()), Default(), []string{"b"})
	p, _ := e.Plan(ctx)
	broken := plan.Action{Op: plan.OpCreate, Target: "b", Resource: "broken",
		Do: func(context.Context) error { return errors.New("boom") }}
	p.Actions = append([]plan.Action{broken}, p.Actions...)
	var out bytes.Buffer
	outcomes, err := e.Apply(ctx, p, &out)
	if err == nil || !strings.Contains(err.Error(), "1 change(s) failed") {
		t.Fatalf("apply %v", err)
	}
	if len(outcomes) != 2 || outcomes[0].Resource != "broken" || outcomes[0].Err == nil || outcomes[1].Err != nil {
		t.Fatalf("outcomes %+v", outcomes)
	}
	if !strings.Contains(out.String(), "done  CREATE b") {
		t.Fatalf("later action skipped: %q", out.String())
	}
}

func TestApplyProgressHidesWhatSteersATerminal(t *testing.T) {
	ctx := context.Background()
	e, _ := New(cfg(t.TempDir()), Default(), []string{"b"})
	p := plan.Plan{Actions: []plan.Action{
		{Op: plan.OpCreate, Target: "b", Resource: "ok\x1b[2K\nforged", Do: func(context.Context) error { return nil }},
		{Op: plan.OpCreate, Target: "b", Resource: "bad", Do: func(context.Context) error { return errors.New("\x1b]52;c;x\a") }},
	}}
	var out bytes.Buffer
	_, _ = e.Apply(ctx, p, &out)
	if strings.Contains(out.String(), "\x1b") || strings.Contains(out.String(), "\nforged") {
		t.Fatalf("progress %q", out.String())
	}
}

// scripted plans "same" for the targets in stuck and nothing for the rest.
type scripted struct{ stuck map[string]bool }

func (s scripted) Plan(_ context.Context, t config.Target) ([]plan.Action, error) {
	if !s.stuck[t.Name] {
		return nil, nil
	}
	return []plan.Action{{Op: plan.OpCreate, Target: t.Name, Resource: "same"}}, nil
}
func (scripted) Measure(context.Context, config.Target) (provider.Live, error) {
	return provider.Live{}, nil
}

func twoTargets() config.Config {
	return config.Config{Version: 1, Targets: []config.Target{
		{Name: "a", Provider: "scripted"}, {Name: "b", Provider: "scripted"}}}
}

func ok(target string) plan.Action {
	return plan.Action{Op: plan.OpCreate, Target: target, Resource: "same", Do: func(context.Context) error { return nil }}
}

func TestVerifyMatchesTargetAndResource(t *testing.T) {
	// b still has "same" outstanding, but only a's was applied.
	e, _ := New(twoTargets(), Providers{"scripted": scripted{stuck: map[string]bool{"b": true}}}, nil)
	var p plan.Plan
	p.Add(ok("a"))
	if _, err := e.Apply(context.Background(), p, &bytes.Buffer{}); err != nil {
		t.Fatalf("collided with another target's resource: %v", err)
	}
	p = plan.Plan{}
	p.Add(ok("b"))
	if _, err := e.Apply(context.Background(), p, &bytes.Buffer{}); err == nil {
		t.Fatal("missed b's outstanding change")
	}
}

func TestVerifyStillRunsAfterAFailure(t *testing.T) {
	e, _ := New(twoTargets(), Providers{"scripted": scripted{stuck: map[string]bool{"a": true}}}, nil)
	var p plan.Plan
	p.Add(plan.Action{Op: plan.OpCreate, Target: "b", Resource: "broken", Do: func(context.Context) error { return errors.New("boom") }}, ok("a"))
	_, err := e.Apply(context.Background(), p, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "1 change(s) failed") || !strings.Contains(err.Error(), "still outstanding") {
		t.Fatalf("apply %v", err)
	}
}

func TestApplyStopsWhenCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	e, _ := New(twoTargets(), Providers{"scripted": scripted{}}, nil)
	var p plan.Plan
	first := plan.Action{Op: plan.OpCreate, Target: "a", Resource: "first", Do: func(context.Context) error { cancel(); return nil }}
	p.Add(first, ok("b"))
	outcomes, err := e.Apply(ctx, p, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "interrupted: 1 change(s) not run") {
		t.Fatalf("apply %v", err)
	}
	if len(outcomes) != 1 || outcomes[0].Resource != "first" {
		t.Fatalf("outcomes %+v", outcomes)
	}
}

func TestSelectAndMissingProvider(t *testing.T) {
	if _, err := New(cfg(""), Default(), []string{"nope"}); err == nil {
		t.Fatal("unknown target accepted")
	}
	e, _ := New(cfg(""), Providers{}, nil)
	if _, err := e.Plan(context.Background()); err == nil {
		t.Fatal("missing provider planned")
	}
	if st := e.Status(context.Background()); st[0].Error == "" {
		t.Fatalf("status %+v", st)
	}
}

// counted has counts, so Status must fill them from Measure.
type counted struct{ stuck }

func (counted) Measure(context.Context, config.Target) (provider.Live, error) {
	return provider.Live{InPlace: 2, Declared: 3, Summary: "2 of 3"}, nil
}

func TestStatusUsesMeasure(t *testing.T) {
	c := cfg(t.TempDir())
	c.Targets[0].Provider = "counted"
	e, _ := New(c, Providers{"counted": counted{}}, []string{"a"})
	st := e.Status(context.Background())
	if st[0].InPlace != 2 || st[0].Declared != 3 || st[0].Summary != "2 of 3" || st[0].InSync() {
		t.Fatalf("status %+v", st)
	}
}

func TestExtrasAnotherTargetDeclaresAreDropped(t *testing.T) {
	rows := dropDeclaredExtras([]TargetItems{
		{Target: "work", Items: []provider.Item{
			{Kind: "brew", Name: "jq", State: provider.Extra},
			{Kind: "brew", Name: "git", State: provider.InPlace},
			{Kind: "cask", Name: "raycast", State: provider.Extra},
		}},
		{Target: "home", Items: []provider.Item{
			{Kind: "brew", Name: "acme/tap/jq", State: provider.Missing},
			{Kind: "brew", Name: "git", State: provider.Extra},
			{Kind: "cask", Name: "raycast", State: provider.Extra},
		}},
	})
	var got []string
	for _, r := range rows {
		for _, i := range r.Items {
			got = append(got, r.Target+" "+i.Name+" "+i.State)
		}
	}
	want := "work git in place, work raycast not declared, home acme/tap/jq missing"
	if strings.Join(got, ", ") != want {
		t.Fatalf("rows\n%s", strings.Join(got, ", "))
	}
}

func TestCaptureNeedsOneCapturingTarget(t *testing.T) {
	e, _ := New(cfg(t.TempDir()), Default(), nil)
	if _, _, err := e.Capture(context.Background()); err == nil || !strings.Contains(err.Error(), "exactly one target") {
		t.Fatalf("two targets: %v", err)
	}
	e, _ = New(cfg(t.TempDir()), Default(), []string{"a"})
	if _, _, err := e.Capture(context.Background()); err == nil || !strings.Contains(err.Error(), "cannot capture") {
		t.Fatalf("localdir: %v", err)
	}
}

func TestSelectLeavesOutOtherProfilesTargets(t *testing.T) {
	cfg := config.Config{Version: 1, Profiles: []string{"everyday"}, Targets: []config.Target{
		{Name: "apps", Provider: "localdir", Path: "a"},
		{Name: "dev", Provider: "localdir", Path: "b", Profiles: []string{"developer"}},
		{Name: "home", Provider: "localdir", Path: "c", Profiles: []string{"everyday", "creative"}},
	}}
	got, err := Select(cfg, nil)
	if err != nil || len(got) != 2 || got[0].Name != "apps" || got[1].Name != "home" {
		t.Fatalf("select %+v %v", got, err)
	}
	if _, err := Select(cfg, []string{"dev"}); err == nil || !strings.Contains(err.Error(), "zc-care profile") {
		t.Fatalf("named dev: %v", err)
	}
	cfg.Profiles = nil
	if got, _ := Select(cfg, nil); len(got) != 3 {
		t.Fatalf("a machine without profiles gets every target: %+v", got)
	}
}

// world is a machine where target "dot" cannot plan until target "pkg" has
// installed what it needs, like dotfiles waiting for chezmoi.
type world struct {
	installed, configured bool
	destructive           bool
}

type installer struct{ w *world }

func (i installer) Plan(context.Context, config.Target) ([]plan.Action, error) {
	if i.w.installed {
		return nil, nil
	}
	return []plan.Action{{Op: plan.OpCreate, Target: "pkg", Resource: "tool",
		Do: func(context.Context) error { i.w.installed = true; return nil }}}, nil
}
func (installer) Measure(context.Context, config.Target) (provider.Live, error) {
	return provider.Live{}, nil
}

type dependent struct {
	w         *world
	permanent bool // the MANUAL is not about the missing tool
}

func (d dependent) Plan(context.Context, config.Target) ([]plan.Action, error) {
	switch {
	case d.w.configured:
		return nil, nil
	case !d.w.installed:
		return []plan.Action{{Op: plan.OpManual, Target: "dot", Resource: "rc", Detail: "tool is not on PATH", Waiting: !d.permanent}}, nil
	}
	return []plan.Action{{Op: plan.OpCreate, Target: "dot", Resource: "rc", Destructive: d.w.destructive,
		Do: func(context.Context) error { d.w.configured = true; return nil }}}, nil
}
func (dependent) Measure(context.Context, config.Target) (provider.Live, error) {
	return provider.Live{}, nil
}

func dependentEngine(t *testing.T, w *world, permanent ...bool) (*Engine, plan.Plan) {
	t.Helper()
	c := config.Config{Version: 1, Targets: []config.Target{
		{Name: "pkg", Provider: "installer", Path: "a"},
		{Name: "dot", Provider: "dependent", Path: "b"},
	}}
	e, err := New(c, Providers{"installer": installer{w}, "dependent": dependent{w, len(permanent) > 0}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	p, err := e.Plan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return e, p
}

func TestApplyFollowingRunsTargetsThatWereManual(t *testing.T) {
	w := &world{}
	e, p := dependentEngine(t, w)
	var out bytes.Buffer
	outcomes, err := e.ApplyFollowing(context.Background(), p, &out)
	if err != nil || !w.configured || len(outcomes) != 2 {
		t.Fatalf("configured %v outcomes %d err %v", w.configured, len(outcomes), err)
	}
	if !strings.Contains(out.String(), "applied and verified") {
		t.Fatalf("out %q", out.String())
	}
}

func TestApplyReportsWhatBecamePossible(t *testing.T) {
	w := &world{}
	e, p := dependentEngine(t, w)
	_, err := e.Apply(context.Background(), p, &bytes.Buffer{})
	if !errors.Is(err, ErrPending) || w.configured || !strings.Contains(err.Error(), "1 change(s)") {
		t.Fatalf("configured %v err %v", w.configured, err)
	}
}

func TestApplyFollowingLeavesDestructiveChangesToConfirm(t *testing.T) {
	w := &world{destructive: true}
	e, p := dependentEngine(t, w)
	_, err := e.ApplyFollowing(context.Background(), p, &bytes.Buffer{})
	if !errors.Is(err, ErrPending) || w.configured {
		t.Fatalf("configured %v err %v", w.configured, err)
	}
}

func TestApplyFollowingIgnoresAPermanentManual(t *testing.T) {
	w := &world{}
	e, p := dependentEngine(t, w, true)
	for name, apply := range map[string]func(context.Context, plan.Plan, io.Writer) ([]Outcome, error){
		"apply": e.Apply, "following": e.ApplyFollowing,
	} {
		*w = world{}
		_, err := apply(context.Background(), p, &bytes.Buffer{})
		if w.configured || err != nil {
			t.Fatalf("%s: configured %v err %v", name, w.configured, err)
		}
	}
}

func TestAddAndPlanRemoveNeedOneTarget(t *testing.T) {
	e, _ := New(cfg(t.TempDir()), Default(), nil)
	if _, err := e.Add(provider.Entry{Kind: "brew", Name: "git"}); err == nil || !strings.Contains(err.Error(), "exactly one target") {
		t.Fatalf("add two targets: %v", err)
	}
	if _, err := e.PlanRemove("brew", "git"); err == nil || !strings.Contains(err.Error(), "exactly one target") {
		t.Fatalf("remove two targets: %v", err)
	}
	e, _ = New(cfg(t.TempDir()), Default(), []string{"a"})
	if _, err := e.Add(provider.Entry{}); err == nil || !strings.Contains(err.Error(), "cannot add") {
		t.Fatalf("add localdir: %v", err)
	}
	if _, err := e.PlanRemove("brew", "git"); err == nil || !strings.Contains(err.Error(), "cannot remove") {
		t.Fatalf("remove localdir: %v", err)
	}
}

type editable struct{ added provider.Entry }

func (editable) Plan(context.Context, config.Target) ([]plan.Action, error) { return nil, nil }
func (editable) Measure(context.Context, config.Target) (provider.Live, error) {
	return provider.Live{}, nil
}
func (e *editable) Add(_ config.Target, entry provider.Entry) error { e.added = entry; return nil }
func (editable) PlanRemove(_ config.Target, kind, name string) (plan.Action, error) {
	return plan.Action{Op: plan.OpDelete, Target: "e", Resource: kind + ":" + name}, nil
}

func TestAddAndPlanRemoveReachTheProvider(t *testing.T) {
	prov := &editable{}
	c := config.Config{Version: 1, Targets: []config.Target{{Name: "e", Provider: "editable", Path: "a"}}}
	e, _ := New(c, Providers{"editable": prov}, nil)
	entry := provider.Entry{Kind: "brew", Name: "git", Why: "vcs"}
	if tgt, err := e.Add(entry); err != nil || tgt.Name != "e" || prov.added != entry {
		t.Fatalf("add %+v %v", prov.added, err)
	}
	p, err := e.PlanRemove("brew", "git")
	if err != nil || len(p.Actions) != 1 || p.Actions[0].Resource != "brew:git" || !p.Destructive() {
		t.Fatalf("remove %+v %v", p, err)
	}
}
