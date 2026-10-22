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
	// A staged file that is gone makes the second rename fail after both
	// old files were moved aside.
	staged := map[string]string{"Brewfile": filepath.Join(dir, "stage-b"), "mise.toml": filepath.Join(dir, "missing")}
	if err := os.WriteFile(staged["Brewfile"], []byte("b"), 0o600); err != nil {
		t.Fatal(err)
	}
	names := []string{"Brewfile", "mise.toml"}
	backups := map[string]string{}
	if err := swapIn(dir, names, staged, backups); err == nil {
		t.Fatal("a missing staged file did not fail the swap")
	}
	restore(dir, names, staged, backups)
	for name, body := range old {
		if got, _ := os.ReadFile(filepath.Join(dir, name)); string(got) != body {
			t.Errorf("%s is %q, want %q", name, got, body)
		}
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if _, kept := old[e.Name()]; !kept && e.Name() != "stage-b" {
			t.Errorf("file left: %s", e.Name())
		}
	}
}

func TestAUserBakFileSurvivesAWrite(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{"Brewfile": "old", "Brewfile.bak": "mine"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := writeAll(dir, []string{"Brewfile"}, map[string][]byte{"Brewfile": []byte("new")}); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(filepath.Join(dir, "Brewfile.bak")); string(got) != "mine" {
		t.Fatalf("user .bak is %q", got)
	}
	if got, _ := os.ReadFile(filepath.Join(dir, "Brewfile")); string(got) != "new" {
		t.Fatalf("Brewfile is %q", got)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 2 {
		t.Fatalf("files left: %v", entries)
	}
}
