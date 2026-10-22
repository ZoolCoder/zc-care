package starter

import (
	"os"
	"path/filepath"
	"testing"
)

func TestForceReplacesALinkInsteadOfWritingThroughIt(t *testing.T) {
	dir, elsewhere := t.TempDir(), filepath.Join(t.TempDir(), "precious")
	if err := os.WriteFile(elsewhere, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, filepath.Join(dir, "Brewfile")); err != nil {
		t.Fatal(err)
	}
	if _, err := Write(Options{Dir: dir, Profiles: []string{"everyday"}, Force: true}); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(elsewhere); string(b) != "keep" {
		t.Fatalf("the link target was written: %q", b)
	}
	if fi, err := os.Lstat(filepath.Join(dir, "Brewfile")); err != nil || fi.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("Brewfile is still a link: %v %v", fi, err)
	}
}

func TestAFailedWriteLeavesNoTempFilesAndTheOldFiles(t *testing.T) {
	dir := t.TempDir()
	old := map[string]string{"zc-care.yaml": "old", "Brewfile": "old brewfile", "mise.toml": "old mise"}
	for name, body := range old {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	// A full directory where the backup of mise.toml goes makes that step
	// fail after Brewfile was already moved aside.
	blocker := filepath.Join(dir, "mise.toml.bak")
	if err := os.MkdirAll(filepath.Join(blocker, "x"), 0o755); err != nil {
		t.Fatal(err)
	}
	err := writeAll(dir, []string{"Brewfile", "mise.toml"}, map[string][]byte{"Brewfile": []byte("b"), "mise.toml": []byte("m")})
	if err == nil {
		t.Fatal("a blocked backup did not fail the write")
	}
	for name, body := range old {
		if got, _ := os.ReadFile(filepath.Join(dir, name)); string(got) != body {
			t.Errorf("%s is %q, want %q", name, got, body)
		}
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if _, kept := old[e.Name()]; !kept && e.Name() != "mise.toml.bak" {
			t.Errorf("file left: %s", e.Name())
		}
	}
}
