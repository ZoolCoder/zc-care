package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLocaldirFileNamesAreCleaned(t *testing.T) {
	cfg, err := Parse([]byte("version: 1\ntargets:\n  - name: a\n    provider: localdir\n    path: a\n    files:\n      ./x.txt: one\n      d//y.txt: two\n"))
	if err != nil {
		t.Fatal(err)
	}
	if f := cfg.Targets[0].Files; f["x.txt"] != "one" || f["d/y.txt"] != "two" || len(f) != 2 {
		t.Fatalf("files %v", f)
	}
	_, err = Parse([]byte("version: 1\ntargets:\n  - name: a\n    provider: localdir\n    path: a\n    files:\n      ./x.txt: one\n      x.txt: two\n"))
	if err == nil || !strings.Contains(err.Error(), "the same file") {
		t.Fatalf("duplicates accepted: %v", err)
	}
}

func TestProfilesFileIsLowercasedAndChecked(t *testing.T) {
	path := filepath.Join(t.TempDir(), "profiles")
	if err := os.WriteFile(path, []byte("Work\n developer \nwork\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := ReadProfiles(path); err != nil || strings.Join(got, ",") != "developer,work" {
		t.Fatalf("profiles %v, %v", got, err)
	}
	if err := os.WriteFile(path, []byte("work mac\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadProfiles(path); err == nil || !strings.Contains(err.Error(), "kebab-case") {
		t.Fatalf("err %v", err)
	}
}
