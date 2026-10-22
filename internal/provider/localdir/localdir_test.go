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

func TestItemsReportEachDeclaredFile(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "ok.txt"), []byte("A"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "off.txt"), []byte("old"), 0o600)
	items, err := New().Items(context.Background(), config.Target{Name: "n", Path: dir,
		Files: map[string]string{"ok.txt": "A", "off.txt": "new", "gone.txt": "G"}})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, i := range items {
		got = append(got, i.Name+"|"+i.State)
	}
	want := "gone.txt|missing off.txt|differs ok.txt|in place"
	if strings.Join(got, " ") != want {
		t.Fatalf("items %v, want %s", got, want)
	}
}

func TestWriteKeepsModeAndLeavesNoTempFile(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "run.sh"), []byte("old"), 0o755); err != nil {
		t.Fatal(err)
	}
	target := config.Target{Name: "n", Path: dir, Files: map[string]string{"run.sh": "new", "fresh.txt": "F"}}
	actions, _ := New().Plan(ctx, target)
	for _, a := range actions {
		if a.Digest == "" {
			t.Fatalf("%s has no digest", a.Resource)
		}
		if err := a.Do(ctx); err != nil {
			t.Fatal(err)
		}
	}
	for name, perm := range map[string]os.FileMode{"run.sh": 0o755, "fresh.txt": 0o600} {
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil || info.Mode().Perm() != perm {
			t.Fatalf("%s: %v, %v", name, info, err)
		}
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 2 {
		t.Fatalf("temp file left behind: %v", entries)
	}
}

// undoAll runs each action's Before, then Do, and returns the revert actions.
func undoAll(t *testing.T, actions []plan.Action) []plan.Action {
	t.Helper()
	ctx := context.Background()
	var undos []plan.Undo
	for _, a := range actions {
		u, err := a.Before(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if u.Blob != nil {
			blob := filepath.Join(t.TempDir(), "blob")
			_ = os.WriteFile(blob, u.Blob, 0o600)
			u.Data["blob"] = blob
		}
		u.Target, u.Resource = a.Target, a.Resource
		undos = append(undos, u)
		if err := a.Do(ctx); err != nil {
			t.Fatal(err)
		}
	}
	return New().Revert(undos)
}

func TestUndoRestoresUpdatedDeletedAndCreatedFiles(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "a.txt"), []byte("old"), 0o640)
	_ = os.WriteFile(filepath.Join(dir, "stray.txt"), []byte("keep me"), 0o600)
	target := config.Target{Name: "n", Path: dir, Prune: true, Files: map[string]string{"a.txt": "new", "b.txt": "B"}}
	actions, _ := New().Plan(ctx, target)
	for _, r := range undoAll(t, actions) {
		if err := r.Do(ctx); err != nil {
			t.Fatal(err)
		}
	}
	for name, want := range map[string]string{"a.txt": "old", "stray.txt": "keep me"} {
		if b, _ := os.ReadFile(filepath.Join(dir, name)); string(b) != want {
			t.Fatalf("%s is %q, want %q", name, b, want)
		}
	}
	if info, _ := os.Stat(filepath.Join(dir, "a.txt")); info.Mode().Perm() != 0o640 {
		t.Fatalf("mode %v", info.Mode().Perm())
	}
	if _, err := os.Stat(filepath.Join(dir, "b.txt")); !os.IsNotExist(err) {
		t.Fatalf("created file still there: %v", err)
	}
}

func TestSymlinkInsideTheRootIsWrittenThrough(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	real := filepath.Join(dir, "real.sh")
	if err := os.WriteFile(real, []byte("old"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link.sh")
	if err := os.Symlink("real.sh", link); err != nil {
		t.Skip(err)
	}
	actions, err := New().Plan(ctx, config.Target{Name: "a", Path: dir, Files: map[string]string{"link.sh": "new"}})
	if err != nil || len(actions) != 1 {
		t.Fatalf("%+v %v", actions, err)
	}
	reverts := undoAll(t, actions)
	if info, err := os.Lstat(link); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("link replaced: %v %v", info, err)
	}
	got, _ := os.ReadFile(real)
	info, _ := os.Stat(real)
	if string(got) != "new" || info.Mode().Perm() != 0o755 {
		t.Fatalf("real file %q mode %v", got, info.Mode())
	}
	for _, r := range reverts {
		if err := r.Do(ctx); err != nil {
			t.Fatal(err)
		}
	}
	got, _ = os.ReadFile(real)
	if _, err := os.Readlink(link); err != nil || string(got) != "old" {
		t.Fatalf("after undo: real %q, link err %v", got, err)
	}
}

func TestSymlinkFileLeadingOutsideIsRefused(t *testing.T) {
	ctx := context.Background()
	outside := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(outside, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(dir, "link")); err != nil {
		t.Skip(err)
	}
	actions, err := New().Plan(ctx, config.Target{Name: "a", Path: dir, Files: map[string]string{"link": "new"}})
	if err != nil || len(actions) != 1 {
		t.Fatalf("%+v %v", actions, err)
	}
	if err := actions[0].Do(ctx); err == nil || !strings.Contains(err.Error(), "outside") {
		t.Fatalf("write through an escaping link: %v", err)
	}
	if got, _ := os.ReadFile(outside); string(got) != "keep" {
		t.Fatalf("outside file changed to %q", got)
	}
	if _, err := os.Readlink(filepath.Join(dir, "link")); err != nil {
		t.Fatalf("link replaced: %v", err)
	}
}

func planWrite(t *testing.T, dir, name string) error {
	t.Helper()
	actions, err := New().Plan(context.Background(), config.Target{Name: "a", Path: dir, Files: map[string]string{name: "new"}})
	if err != nil || len(actions) != 1 {
		t.Fatalf("%+v %v", actions, err)
	}
	return actions[0].Do(context.Background())
}

func TestDanglingSymlinkIsRefused(t *testing.T) {
	dir := t.TempDir()
	if err := os.Symlink("missing.sh", filepath.Join(dir, "link")); err != nil {
		t.Skip(err)
	}
	if err := planWrite(t, dir, "link"); err == nil || !strings.Contains(err.Error(), "link is a symlink to a missing file") {
		t.Fatalf("err %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "missing.sh")); !os.IsNotExist(err) {
		t.Fatalf("target created: %v", err)
	}
}

func TestSymlinkToDirectoryIsRefused(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "d"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("d", filepath.Join(dir, "link")); err != nil {
		t.Skip(err)
	}
	if err := planWrite(t, dir, "link"); err == nil || !strings.Contains(err.Error(), "link is a symlink to a directory") {
		t.Fatalf("err %v", err)
	}
}

func TestSymlinkIntoASubdirectoryIsWrittenThrough(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "sub", "real"), []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("sub/real", filepath.Join(dir, "link")); err != nil {
		t.Skip(err)
	}
	if err := planWrite(t, dir, "link"); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(filepath.Join(dir, "sub", "real")); string(got) != "new" {
		t.Fatalf("real file %q", got)
	}
	if _, err := os.Readlink(filepath.Join(dir, "link")); err != nil {
		t.Fatalf("link replaced: %v", err)
	}
}
