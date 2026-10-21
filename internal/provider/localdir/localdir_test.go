package localdir

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
)

func TestPlanAndApplyConverge(t *testing.T) {
	ctx := context.Background()
	dir := filepath.Join(t.TempDir(), "out")
	target := config.Target{Name: "notes", Path: dir, Prune: true,
		Files: map[string]string{"a.txt": "A", "sub/b.txt": "B"}}

	actions, err := New().Plan(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 2 || actions[0].Op != plan.OpCreate || actions[1].Resource != "sub/b.txt" {
		t.Fatalf("first plan %+v", actions)
	}
	for _, a := range actions {
		if err := a.Do(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "sub", "b.txt")); string(b) != "B" {
		t.Fatalf("b.txt %q", b)
	}

	_ = os.WriteFile(filepath.Join(dir, "a.txt"), []byte("changed"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "stray.txt"), []byte("x"), 0o600)
	actions, _ = New().Plan(ctx, target)
	ops := []plan.Op{}
	for _, a := range actions {
		ops = append(ops, a.Op)
		if err := a.Do(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if len(ops) != 2 || ops[0] != plan.OpUpdate || ops[1] != plan.OpDelete {
		t.Fatalf("drift ops %v", ops)
	}
	if actions, _ := New().Plan(ctx, target); len(actions) != 0 {
		t.Fatalf("not converged: %+v", actions)
	}
	live, err := New().Measure(ctx, target)
	if err != nil || !strings.HasPrefix(live.Summary, "2 of 2") {
		t.Fatalf("status %q %v", live.Summary, err)
	}
}

func TestPruneOffKeepsStrays(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "stray.txt"), []byte("x"), 0o600)
	actions, err := New().Plan(context.Background(), config.Target{Name: "a", Path: dir})
	if err != nil || len(actions) != 0 {
		t.Fatalf("%+v %v", actions, err)
	}
}

func TestSymlinkCannotLeadOutside(t *testing.T) {
	outside := t.TempDir()
	dir := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(dir, "link")); err != nil {
		t.Skip(err)
	}
	ctx := context.Background()
	actions, err := New().Plan(ctx, config.Target{Name: "a", Path: dir, Files: map[string]string{"link/x.txt": "x"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := actions[0].Do(ctx); err == nil {
		t.Fatal("write through a symlink escaped the target directory")
	}
	if _, err := os.Stat(filepath.Join(outside, "x.txt")); err == nil {
		t.Fatal("file written outside the target")
	}
}
