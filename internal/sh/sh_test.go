package sh

import (
	"context"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestExecOutputCarriesStderr(t *testing.T) {
	if !(Exec{}).Has("go") {
		t.Skip("go is not on PATH")
	}
	out, err := Exec{}.Output(context.Background(), "go", "env", "GOOS")
	if err != nil || strings.TrimSpace(string(out)) == "" {
		t.Fatalf("%q %v", out, err)
	}
	_, err = Exec{}.Output(context.Background(), "go", "no-such-command")
	if err == nil || !strings.Contains(err.Error(), "go no-such-command") || !strings.Contains(err.Error(), "unknown command") {
		t.Fatalf("err %v", err)
	}
}

func TestFake(t *testing.T) {
	var seen string
	f := &Fake{Out: map[string]string{"a b": "out"}, Programs: []string{"a"}, OnRun: func(l string) { seen = l }}
	if out, err := f.Output(context.Background(), "a", "b"); err != nil || string(out) != "out" {
		t.Fatal(out, err)
	}
	if _, err := f.Output(context.Background(), "a", "c"); err == nil {
		t.Fatal("unknown command answered")
	}
	if err := f.Run(context.Background(), "x", "y"); err != nil || seen != "x y" || f.Ran[0] != "x y" {
		t.Fatal(err, seen, f.Ran)
	}
	if !f.Has("a") || f.Has("b") {
		t.Fatal("Has")
	}
}

func TestAskpassOnlyWithoutTerminal(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	t.Setenv("SUDO_ASKPASS", "")
	if hasTerminal() {
		t.Skip("running in a terminal")
	}
	env := askpassEnv()
	if !slices.ContainsFunc(env, func(v string) bool {
		path, ok := strings.CutPrefix(v, "SUDO_ASKPASS=")
		return ok && filepath.IsAbs(path)
	}) {
		t.Fatalf("no askpass in %v", env)
	}
	t.Setenv("SUDO_ASKPASS", "/bin/mine")
	if env := askpassEnv(); env != nil {
		t.Fatal("overrode the caller's SUDO_ASKPASS")
	}
}
