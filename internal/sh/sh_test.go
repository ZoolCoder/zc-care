package sh

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
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

func TestAskpassReplacesAPlantedSymlink(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	path, err := writeAskpass()
	if err != nil {
		t.Fatal(err)
	}
	victim := filepath.Join(t.TempDir(), "victim")
	if err := os.WriteFile(victim, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, path); err != nil {
		t.Fatal(err)
	}
	if _, err := writeAskpass(); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(victim); string(b) != "keep" {
		t.Fatalf("wrote through the link: %q", b)
	}
	fi, err := os.Lstat(path)
	if err != nil || fi.Mode()&os.ModeSymlink != 0 || fi.Mode().Perm() != 0o700 {
		t.Fatalf("askpass is %v, %v", fi, err)
	}
}

func TestOutputReturnsPromptlyAfterCancel(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	// The background sleep inherits the output pipe and outlives the shell.
	_, err := (Exec{}).Output(ctx, "sh", "-c", "sleep 30 & sleep 30")
	if err == nil {
		t.Fatal("cancelled command succeeded")
	}
	if took := time.Since(start); took > 15*time.Second {
		t.Fatalf("Output took %v after cancel", took)
	}
}

func TestAGrandchildHoldingTheOutputOpenIsNotAFailure(t *testing.T) {
	if testing.Short() {
		t.Skip("waits out the 5s kill grace")
	}
	if !(Exec{}).Has("sh") {
		t.Skip("sh is not on PATH")
	}
	var buf strings.Builder
	e := Exec{Stdout: &buf, Stderr: &buf}
	if err := e.Run(context.Background(), "sh", "-c", "sleep 20 & echo hi"); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(buf.String(), "hi") {
		t.Fatalf("output %q", buf.String())
	}
	out, err := Exec{}.Output(context.Background(), "sh", "-c", "sleep 20 & echo hi")
	if err != nil || strings.TrimSpace(string(out)) != "hi" {
		t.Fatalf("Output %q, %v", out, err)
	}
}
