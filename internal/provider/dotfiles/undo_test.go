package dotfiles

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
)

func TestRevertRestoresContentAndMode(t *testing.T) {
	file := filepath.Join(t.TempDir(), "sub", ".zshrc")
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("old\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	u, err := before(file, false)
	if err != nil || u.Verb != "restore" || string(u.Blob) != "old\n" {
		t.Fatalf("undo %+v, %v", u, err)
	}
	// The journal keeps the blob in its own file and points at it.
	blob := filepath.Join(t.TempDir(), "x.blob")
	if err := os.WriteFile(blob, u.Blob, 0o600); err != nil {
		t.Fatal(err)
	}
	u.Data["blob"] = blob
	if err := os.WriteFile(file, []byte("new\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	actions := Provider{}.Revert([]plan.Undo{u})
	if len(actions) != 1 || !actions[0].Destructive {
		t.Fatalf("actions %+v: an overwrite must need confirmation", actions)
	}
	if err := actions[0].Do(context.Background()); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(file)
	info, _ := os.Stat(file)
	if string(got) != "old\n" || info.Mode().Perm() != 0o600 {
		t.Fatalf("content %q mode %v", got, info.Mode().Perm())
	}
}

func TestRevertRemovesAFileApplyCreated(t *testing.T) {
	file := filepath.Join(t.TempDir(), ".new")
	u, err := before(file, false)
	if err != nil || u.Verb != "remove" {
		t.Fatalf("undo %+v, %v", u, err)
	}
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	actions := Provider{}.Revert([]plan.Undo{u})
	if actions[0].Op != plan.OpDelete {
		t.Fatalf("op %s", actions[0].Op)
	}
	if err := actions[0].Do(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Fatalf("file still there: %v", err)
	}
}

func TestScriptsCannotBeUndone(t *testing.T) {
	u, err := before("/home/me/install.sh", true)
	if err != nil || u.Reason == "" {
		t.Fatalf("undo %+v, %v", u, err)
	}
}

func TestRevertRestoresASymlinkAsALink(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, ".zshrc")
	// The link dangles: a stat would see no file and record "remove".
	if err := os.Symlink(filepath.Join(dir, "gone"), file); err != nil {
		t.Fatal(err)
	}
	u, err := before(file, false)
	if err != nil || u.Verb != "symlink" || !u.KeepOnError {
		t.Fatalf("undo %+v, %v", u, err)
	}
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("applied\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	actions := Provider{}.Revert([]plan.Undo{u})
	if err := actions[0].Do(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got, err := os.Readlink(file); err != nil || got != filepath.Join(dir, "gone") {
		t.Fatalf("link %q, %v", got, err)
	}
}

func TestRevertPreviewLeavesARecordBehindALink(t *testing.T) {
	file := filepath.Join(t.TempDir(), ".rc")
	if err := os.WriteFile(file, []byte("first apply"), 0o600); err != nil {
		t.Fatal(err)
	}
	older := provider.StampFileUndo(provider.SavedFileUndo("dotfiles", file, []byte("original"), 0o600))
	if err := os.WriteFile(file, []byte("second apply"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := plan.Undo{Provider: "dotfiles", Verb: "symlink", Data: map[string]string{"path": file, "target": "elsewhere"}}
	if got := (Provider{}).Revert([]plan.Undo{link, older})[1].Detail; strings.Contains(got, "refused") {
		t.Fatalf("detail %q", got)
	}
}

func TestRevertPreviewJudgesAFileALinkPointsAt(t *testing.T) {
	dir := t.TempDir()
	target, link := filepath.Join(dir, "b"), filepath.Join(dir, ".a")
	if err := os.WriteFile(target, []byte("applied"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	u := provider.StampFileUndo(provider.SavedFileUndo("dotfiles", target, []byte("original"), 0o600))
	if err := os.WriteFile(target, []byte("my edit"), 0o600); err != nil {
		t.Fatal(err)
	}
	undos := []plan.Undo{{Provider: "dotfiles", Verb: "symlink", Data: map[string]string{"path": link, "target": target}}, u}
	if got := (Provider{}).Revert(undos)[1].Detail; !strings.Contains(got, "refused") {
		t.Fatalf("detail %q", got)
	}
}

func TestRevertPreviewNamesAnEditedFile(t *testing.T) {
	file := filepath.Join(t.TempDir(), ".rc")
	if err := os.WriteFile(file, []byte("applied"), 0o600); err != nil {
		t.Fatal(err)
	}
	u := provider.StampFileUndo(provider.SavedFileUndo("dotfiles", file, []byte("original"), 0o600))
	if err := os.WriteFile(file, []byte("my edit"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := (Provider{}).Revert([]plan.Undo{u})[0].Detail; !strings.Contains(got, "refused: "+file+" changed since the apply") {
		t.Fatalf("detail %q", got)
	}
}

func TestRevertRefusesAFileEditedAfterTheApply(t *testing.T) {
	file := filepath.Join(t.TempDir(), ".new")
	u, err := before(file, false)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	u = provider.StampFileUndo(u)
	if err := os.WriteFile(file, []byte("edited by hand"), 0o644); err != nil {
		t.Fatal(err)
	}
	err = Provider{}.Revert([]plan.Undo{u})[0].Do(context.Background())
	if err == nil || !strings.Contains(err.Error(), "changed since the apply") {
		t.Fatalf("err %v", err)
	}
	if got, _ := os.ReadFile(file); string(got) != "edited by hand" {
		t.Fatalf("edit lost: %q", got)
	}
}
