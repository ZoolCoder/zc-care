package provider

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/plan"
)

func TestDigestSeparatesParts(t *testing.T) {
	if Digest([]byte("ab"), []byte("c")) == Digest([]byte("a"), []byte("bc")) {
		t.Fatal("two splits of the same bytes share a digest")
	}
	if len(Digest([]byte("x"))) != 16 {
		t.Fatalf("digest %q", Digest([]byte("x")))
	}
}

func TestFileBeforeFollowsASymlinkAndKeepsTheMode(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "real.json")
	if err := os.WriteFile(real, []byte("old"), 0o640); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link.json")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	u, err := FileBefore("p", link)
	if err != nil || u.Verb != "restore" || string(u.Blob) != "old" || u.Data["mode"] != "640" {
		t.Fatalf("undo %+v, %v", u, err)
	}
	if want, _ := filepath.EvalSymlinks(real); u.Data["path"] != want {
		t.Fatalf("path %q, want %q", u.Data["path"], want)
	}
	if u, _ := FileBefore("p", filepath.Join(dir, "nope")); u.Verb != "remove" {
		t.Fatalf("undo %+v", u)
	}
}

// restoreRecord is the journal's view of a file the apply replaced: the saved
// content in a blob file, the apply's result stamped in.
func restoreRecord(t *testing.T, stamp bool) (plan.Undo, string) {
	t.Helper()
	dir := t.TempDir()
	file := filepath.Join(dir, "conf")
	blob := filepath.Join(dir, "blob")
	for path, content := range map[string]string{blob: "old", file: "applied"} {
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	u := SavedFileUndo("p", file, []byte("old"), 0o600)
	u.Data["blob"] = blob
	if stamp {
		u = StampFileUndo(u)
	}
	return u, file
}

func runRevert(t *testing.T, u plan.Undo) error {
	t.Helper()
	return RevertFiles([]plan.Undo{u})[0].Do(context.Background())
}

func TestRevertRestoresAnUnchangedFile(t *testing.T) {
	u, file := restoreRecord(t, true)
	if err := runRevert(t, u); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(file); string(got) != "old" {
		t.Fatalf("content %q", got)
	}
}

func TestRevertRefusesAFileEditedAfterTheApply(t *testing.T) {
	u, file := restoreRecord(t, true)
	if err := os.WriteFile(file, []byte("my edit"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := runRevert(t, u)
	if err == nil || !strings.Contains(err.Error(), file+" changed since the apply") {
		t.Fatalf("err %v", err)
	}
	if got, _ := os.ReadFile(file); string(got) != "my edit" {
		t.Fatalf("edit lost: %q", got)
	}
}

func TestRevertWithoutADigestStillRestores(t *testing.T) {
	u, file := restoreRecord(t, false)
	if err := os.WriteFile(file, []byte("anything"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := runRevert(t, u); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(file); string(got) != "old" {
		t.Fatalf("content %q", got)
	}
}

func TestRevertRefusesWhenTheFolderIsGone(t *testing.T) {
	u, file := restoreRecord(t, false)
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	blob := u.Data["blob"]
	moved := filepath.Join(t.TempDir(), "blob")
	if err := os.Rename(blob, moved); err != nil {
		t.Fatal(err)
	}
	u.Data["blob"] = moved
	u.Data["path"] = filepath.Join(filepath.Dir(file), "gone", "conf")
	err := runRevert(t, u)
	if err == nil || !strings.Contains(err.Error(), "its folder is gone") {
		t.Fatalf("err %v", err)
	}
}

func TestRevertRemoveRefusesAFileEditedAfterTheApply(t *testing.T) {
	file := filepath.Join(t.TempDir(), "new")
	if err := os.WriteFile(file, []byte("applied"), 0o600); err != nil {
		t.Fatal(err)
	}
	u := StampFileUndo(NewFileUndo("p", file))
	if err := os.WriteFile(file, []byte("edited"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := runRevert(t, u); err == nil {
		t.Fatal("removed an edited file")
	}
	if err := os.WriteFile(file, []byte("applied"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := runRevert(t, u); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(file); err == nil {
		t.Fatal("file survived")
	}
}

func TestTwoRecordsForOnePathRevertInOrder(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "conf")
	blobs := []string{filepath.Join(dir, "b1"), filepath.Join(dir, "b2")}
	for i, content := range []string{"v0", "v1"} {
		if err := os.WriteFile(blobs[i], []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(file, []byte("v2"), 0o600); err != nil {
		t.Fatal(err)
	}
	first := SavedFileUndo("p", file, []byte("v0"), 0o600)
	first.Data["blob"] = blobs[0]
	second := SavedFileUndo("p", file, []byte("v1"), 0o600)
	second.Data["blob"] = blobs[1]
	// The journal stamps only the newest record; the older one is unstamped.
	second = StampFileUndo(second)
	// Undo runs newest first.
	actions := RevertFiles([]plan.Undo{second, first})
	for i, a := range actions {
		if err := a.Do(context.Background()); err != nil {
			t.Fatalf("revert %d: %v", i, err)
		}
	}
	if got, _ := os.ReadFile(file); string(got) != "v0" {
		t.Fatalf("content %q", got)
	}
}
