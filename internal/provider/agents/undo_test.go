package agents

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/plan"
)

func find(t *testing.T, actions []plan.Action, resource string) plan.Action {
	t.Helper()
	for _, a := range actions {
		if a.Resource == resource {
			return a
		}
	}
	t.Fatalf("no action %q", resource)
	return plan.Action{}
}

func TestRulesRefuseAnEditMadeAfterThePlan(t *testing.T) {
	p, target, home, _ := setup(t)
	actions, _ := p.Plan(context.Background(), target)
	a := find(t, actions, "rules (claude)")
	if a.Digest == "" {
		t.Fatal("rules action has no digest")
	}
	write(t, filepath.Join(home, ".claude/CLAUDE.md"), "# Mine, edited\n")
	err := a.Do(context.Background())
	if err == nil || !strings.Contains(err.Error(), "changed since the plan") {
		t.Fatalf("err %v", err)
	}
	if got := read(t, filepath.Join(home, ".claude/CLAUDE.md")); got != "# Mine, edited\n" {
		t.Fatalf("edit lost: %q", got)
	}
}

func TestSkillCopyKeepsTheSourceMode(t *testing.T) {
	p, target, home, _ := setup(t)
	src := filepath.Dir(target.File)
	write(t, filepath.Join(src, "skills/review/run.sh"), "#!/bin/sh\n")
	for name, mode := range map[string]os.FileMode{"run.sh": 0o755, "SKILL.md": 0o644} {
		if err := os.Chmod(filepath.Join(src, "skills/review", name), mode); err != nil {
			t.Fatal(err)
		}
	}
	actions, _ := p.Plan(context.Background(), target)
	a := find(t, actions, "skill review (claude)")
	if a.Digest == "" {
		t.Fatal("skill action has no digest")
	}
	apply(t, []plan.Action{a})
	for name, want := range map[string]os.FileMode{"run.sh": 0o755, "SKILL.md": 0o644} {
		info, err := os.Stat(filepath.Join(home, ".claude/skills/review", name))
		if err != nil || info.Mode().Perm() != want {
			t.Fatalf("%s: %v, %v", name, info, err)
		}
	}
}

func TestServerDigestNeverHoldsASecret(t *testing.T) {
	a := serverDigest("claude", "docs", Server{Command: "npx", Env: map[string]string{"T": "${keychain:svc}"}})
	b := serverDigest("claude", "docs", Server{Command: "npx", Env: map[string]string{"T": "${keychain:svc}"}})
	if a == "" || a != b {
		t.Fatalf("digest %q %q", a, b)
	}
}

func TestRulesAndServerChangesCanBeUndone(t *testing.T) {
	p, target, home, _ := setup(t)
	ctx := context.Background()
	actions, _ := p.Plan(ctx, target)
	var undos []plan.Undo
	for _, res := range []string{"rules (claude)", "docs (claude)"} {
		a := find(t, actions, res)
		u, err := a.Before(ctx)
		if err != nil || u.Verb != "restore" {
			t.Fatalf("%s undo %+v, %v", res, u, err)
		}
		blob := filepath.Join(t.TempDir(), "blob")
		write(t, blob, string(u.Blob))
		u.Data["blob"] = blob
		undos = append(undos, u)
		apply(t, []plan.Action{a})
	}
	// The undo records come newest first.
	apply(t, p.Revert(undos))
	if got := read(t, filepath.Join(home, ".claude/CLAUDE.md")); got != "# Mine\n" {
		t.Fatalf("rules %q", got)
	}
	if got := read(t, filepath.Join(home, ".claude.json")); strings.Contains(got, `"docs"`) {
		t.Fatalf("server still there: %s", got)
	}
}
