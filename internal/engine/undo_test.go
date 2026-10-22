package engine

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/plan"
)

func TestApplyRecordsWhatTheActionReplaced(t *testing.T) {
	var order []string
	p := plan.Plan{}
	p.Add(plan.Action{Op: plan.OpUpdate, Target: "a", Resource: "r",
		Before: func(context.Context) (plan.Undo, error) {
			order = append(order, "before")
			return plan.Undo{Provider: "settings", Verb: "restore"}, nil
		},
		Do: func(context.Context) error { order = append(order, "do"); return nil }})
	p.Add(plan.Action{Op: plan.OpUpdate, Target: "a", Resource: "unreadable",
		Before: func(context.Context) (plan.Undo, error) { return plan.Undo{}, errors.New("no access") },
		Do:     func(context.Context) error { return nil }})

	outcomes, err := Run(context.Background(), p, &bytes.Buffer{})
	if err != nil || len(outcomes) != 2 {
		t.Fatalf("%v %+v", err, outcomes)
	}
	if strings.Join(order, ",") != "before,do" {
		t.Fatalf("the state must be read before the change: %v", order)
	}
	if u := outcomes[0].Undo; u == nil || u.Target != "a" || u.Resource != "r" || u.Verb != "restore" {
		t.Fatalf("undo %+v", u)
	}
	// A state that cannot be read does not stop the change; it only cannot
	// be undone.
	if u := outcomes[1].Undo; u == nil || !strings.Contains(u.Reason, "no access") {
		t.Fatalf("undo %+v", u)
	}
}

func TestRunDoesNotVerifyAndSoSuitsAnUndo(t *testing.T) {
	e, _ := New(twoTargets(), Providers{"scripted": scripted{stuck: map[string]bool{"a": true}}}, nil)
	p := plan.Plan{}
	p.Add(ok("a"))
	var out bytes.Buffer
	if _, err := Run(context.Background(), p, &out); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Apply(context.Background(), p, &out); err == nil {
		t.Fatal("Apply should have failed verification: the target still differs")
	}
}

// reverter turns each record into one action that notes it ran.
type reverter struct {
	scripted
	ran *[]string
}

func (r reverter) Revert(undos []plan.Undo) []plan.Action {
	var out []plan.Action
	for _, u := range undos {
		out = append(out, plan.Action{Op: plan.OpUpdate, Target: u.Target, Resource: u.Resource,
			Do: func(context.Context) error { *r.ran = append(*r.ran, u.Resource); return nil }})
	}
	return out
}

func TestRevertAsksProvidersAndListsWhatCannotBeUndone(t *testing.T) {
	var ran []string
	providers := Providers{"r": reverter{ran: &ran}, "plain": scripted{}}
	p := Revert(providers, []plan.Undo{
		{Provider: "r", Target: "t", Resource: "one", Verb: "restore"},
		{Provider: "plain", Target: "t", Resource: "two", Verb: "restore"},
		{Provider: "r", Target: "t", Resource: "three", Reason: "an upgrade is not downgraded"},
		plan.NoUndo(),
	})
	if len(p.Actions) != 3 {
		t.Fatalf("actions %+v: a restart record must be skipped", p.Actions)
	}
	var manual []string
	for _, a := range p.Actions {
		if a.Op == plan.OpManual {
			manual = append(manual, a.Resource+": "+a.Detail)
		}
	}
	if len(manual) != 2 || !strings.Contains(manual[1], "an upgrade is not downgraded") {
		t.Fatalf("manual %q", manual)
	}
	if _, err := Run(context.Background(), p, &bytes.Buffer{}); err != nil || len(ran) != 1 || ran[0] != "one" {
		t.Fatalf("%v ran %v", err, ran)
	}
}

func TestAFailedChangeKeepsItsUndoWhenAsked(t *testing.T) {
	fail := func(context.Context) error { return errors.New("half done") }
	p := plan.Plan{}
	p.Add(plan.Action{Op: plan.OpUpdate, Target: "a", Resource: "keeps",
		Before: func(context.Context) (plan.Undo, error) {
			return plan.Undo{Provider: "dotfiles", Verb: "restore", KeepOnError: true}, nil
		}, Do: fail})
	p.Add(plan.Action{Op: plan.OpUpdate, Target: "a", Resource: "drops",
		Before: func(context.Context) (plan.Undo, error) {
			return plan.Undo{Provider: "packages", Verb: "uninstall"}, nil
		},
		Do: fail})
	outcomes, err := Run(context.Background(), p, &bytes.Buffer{})
	if err == nil || len(outcomes) != 2 {
		t.Fatalf("%v %+v", err, outcomes)
	}
	if u := outcomes[0].Undo; u == nil || !u.Partial || u.Verb != "restore" {
		t.Fatalf("undo %+v", u)
	}
	if outcomes[1].Undo != nil {
		t.Fatalf("undo %+v", outcomes[1].Undo)
	}
}

func TestPlanReportsEveryTargetError(t *testing.T) {
	c := cfg(t.TempDir())
	c.Targets[0].Provider, c.Targets[1].Provider = "nope", "nada"
	e, _ := New(c, Providers{}, nil)
	_, err := e.Plan(context.Background())
	if err == nil || !strings.Contains(err.Error(), `"nope"`) || !strings.Contains(err.Error(), `"nada"`) {
		t.Fatalf("err %v", err)
	}
}
