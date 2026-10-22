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
	if err := os.WriteFile(filepath.Join(dir, "zc-care.yaml"), []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	// A directory where mise.toml goes makes the last rename fail.
	if err := os.Mkdir(filepath.Join(dir, "mise.toml"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writeAll(dir, []string{"Brewfile", "mise.toml"}, map[string][]byte{"Brewfile": []byte("b"), "mise.toml": []byte("m")}); err == nil {
		t.Fatal("rename over a directory worked")
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if e.Name() != "zc-care.yaml" && e.Name() != "mise.toml" && e.Name() != "Brewfile" {
			t.Errorf("temp file left: %s", e.Name())
		}
	}
}
