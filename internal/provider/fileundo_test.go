package provider

import (
	"os"
	"path/filepath"
	"testing"
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
