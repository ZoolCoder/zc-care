package engine

import (
	"bytes"
	"context"
	"errors"
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
func (stuck) Status(context.Context, config.Target) (string, error) { return "stuck", nil }

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
	if err := e.Apply(ctx, p, &out); err != nil {
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
	if err := e.Apply(ctx, p, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "still outstanding") {
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
	if err := e.Apply(ctx, p, &out); err == nil || !strings.Contains(err.Error(), "1 change(s) failed") {
		t.Fatalf("apply %v", err)
	}
	if !strings.Contains(out.String(), "done  CREATE b") {
		t.Fatalf("later action skipped: %q", out.String())
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

// counted measures, so Status must fill the counts from Measure.
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
