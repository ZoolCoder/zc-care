package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/manifest"
)

// TestMain points the state and data folders at a scratch folder, so no test
// writes to the activity log or plans of the person running it.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "zc-care-test-")
	if err != nil {
		panic(err)
	}
	_ = os.Setenv("XDG_STATE_HOME", filepath.Join(dir, "state"))
	_ = os.Setenv("XDG_DATA_HOME", filepath.Join(dir, "data"))
	// doctor reads keys and agent configs from the home folder; tests must
	// never see the real ones.
	_ = os.Setenv("HOME", filepath.Join(dir, "home"))
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}

// fixture writes a config with one pruned target and returns its path and the
// target directory.
func fixture(t *testing.T) (cfg, dir string) {
	t.Helper()
	root := t.TempDir()
	cfg = filepath.Join(root, name+".yaml")
	body := "version: 1\ntargets:\n  - name: notes\n    provider: localdir\n    path: out\n    prune: true\n    files:\n      a.txt: \"A\\n\"\n"
	if err := os.WriteFile(cfg, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return cfg, filepath.Join(root, "out")
}

func run(t *testing.T, stdin string, args ...string) (string, error) {
	t.Helper()
	var out, errOut bytes.Buffer
	err := runCLI(args, strings.NewReader(stdin), &out, &errOut)
	return out.String() + errOut.String(), err
}

func TestPlanApplyConverge(t *testing.T) {
	cfg, dir := fixture(t)
	out, err := run(t, "", "plan", "-config", cfg, "-exit-code")
	if !errors.Is(err, errDrift) || !strings.Contains(out, "CREATE  notes  a.txt") {
		t.Fatalf("plan: %v\n%s", err, out)
	}
	if out, err = run(t, "", "apply", "-config", cfg); err != nil || !strings.Contains(out, "applied and verified") {
		t.Fatalf("apply: %v\n%s", err, out)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "a.txt")); string(b) != "A\n" {
		t.Fatalf("a.txt %q", b)
	}
	if _, err := run(t, "", "plan", "-config", cfg, "-exit-code"); err != nil {
		t.Fatalf("converged plan: %v", err)
	}
	if out, _ := run(t, "", "status", "-config", cfg); !strings.Contains(out, "1 of 1 declared files") {
		t.Fatalf("status %s", out)
	}
}

func TestSavedPlanRefusesWhenTheWorldMoved(t *testing.T) {
	cfg, dir := fixture(t)
	saved := filepath.Join(t.TempDir(), "plan.json")
	if _, err := run(t, "", "plan", "-config", cfg, "-json", "-out", saved); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(saved); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("saved plan %v %v", info, err)
	}
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "a.txt"), []byte("other"), 0o600)
	if _, err := run(t, "", "apply", "-config", cfg, saved); err == nil || !strings.Contains(err.Error(), "changed since") {
		t.Fatalf("moved world applied: %v", err)
	}
	if _, err := run(t, "", "apply", "-config", cfg, "-target", "other", saved); err == nil {
		t.Fatal("different selection accepted")
	}
}

func TestOnlyKeepsOneChangeAndASavedPlanRemembersIt(t *testing.T) {
	cfg, dir := fixture(t)
	body := "version: 1\ntargets:\n  - name: notes\n    provider: localdir\n    path: out\n    files:\n      a.txt: A\n      b.txt: B\n"
	if err := os.WriteFile(cfg, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	saved := filepath.Join(t.TempDir(), "plan.json")
	out, err := run(t, "", "plan", "-config", cfg, "-only", "b.txt", "-upgrade", "-out", saved)
	if err != nil || strings.Contains(out, "a.txt") || !strings.Contains(out, "b.txt") {
		t.Fatalf("plan -only: %v\n%s", err, out)
	}
	if _, err := run(t, "", "apply", "-config", cfg, "-only", "a.txt", saved); err == nil {
		t.Fatal("different -only accepted")
	}
	if out, err := run(t, "", "apply", "-config", cfg, saved); err != nil {
		t.Fatalf("apply saved: %v\n%s", err, out)
	}
	if _, err := os.Stat(filepath.Join(dir, "a.txt")); err == nil {
		t.Fatal("a.txt written, though the plan was only b.txt")
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "b.txt")); string(b) != "B" {
		t.Fatalf("b.txt %q", b)
	}
}

func TestDeletionsNeedAYes(t *testing.T) {
	cfg, dir := fixture(t)
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "a.txt"), []byte("A\n"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "stray.txt"), []byte("x"), 0o600)

	if _, err := run(t, "", "apply", "-config", cfg); !errors.Is(err, errCancelled) {
		t.Fatalf("no answer: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "stray.txt")); err != nil {
		t.Fatal("deleted without a yes")
	}
	if _, err := run(t, "yes\n", "apply", "-config", cfg); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "stray.txt")); err == nil {
		t.Fatal("stray.txt survived a yes")
	}
}

func TestValidateDoctorVersionAndErrors(t *testing.T) {
	cfg, _ := fixture(t)
	if out, err := run(t, "", "validate", "-config", cfg); err != nil || !strings.Contains(out, "1 target(s), valid") {
		t.Fatalf("validate: %v %s", err, out)
	}
	out, err := run(t, "", "doctor", "-config", cfg, "-json")
	var report struct {
		Checks []struct{ Name, Status string }
	}
	jerr := json.Unmarshal([]byte(out[:strings.LastIndex(out, "}")+1]), &report)
	// The security and AI checks read this machine, so they are not counted.
	install := slices.DeleteFunc(report.Checks, func(c struct{ Name, Status string }) bool {
		return strings.HasPrefix(c.Name, "security ") || strings.HasPrefix(c.Name, "ai ")
	})
	if jerr != nil || len(install) != 4 {
		t.Fatalf("doctor: %v %v\n%s", err, jerr, out)
	}
	if out, _ := run(t, "", "version"); out != "dev\n" {
		t.Fatalf("version %q", out)
	}
	if _, err := run(t, "", "nope"); err == nil {
		t.Fatal("unknown command accepted")
	}
	if _, err := run(t, "version: 1\ntargets: [{name: x, provider: localdir, path: out, prune: true}]\n", "apply", "-config", "-"); err != nil {
		t.Fatalf("empty stdin plan: %v", err)
	}
	out, _ = run(t, "", "help")
	for cmd := range optional {
		if !strings.Contains(out, name+" "+cmd) {
			t.Fatalf("usage lacks %s:\n%s", cmd, out)
		}
	}
}

// Under mcp, standard output is the protocol: an installer's output must go
// to the command's stderr, never its stdout.
func TestInstallerOutputGoesToStderr(t *testing.T) {
	bin := t.TempDir()
	brew := "#!/bin/sh\ncase \"$1\" in install) echo INSTALLER-OUTPUT;; esac\n"
	if err := os.WriteFile(filepath.Join(bin, "brew"), []byte(brew), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "Brewfile"), []byte("brew \"hello\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(dir, "zc-care.yaml")
	body := "version: 1\ntargets: [{name: pk, provider: packages, file: Brewfile}]\n"
	if err := os.WriteFile(cfg, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	var out, errOut bytes.Buffer
	// The fake never really installs, so verify reports it outstanding.
	_ = runCLI([]string{"apply", "-config", cfg}, strings.NewReader(""), &out, &errOut)
	if strings.Contains(out.String(), "INSTALLER-OUTPUT") || !strings.Contains(errOut.String(), "INSTALLER-OUTPUT") {
		t.Fatalf("stdout %q\nstderr %q", out.String(), errOut.String())
	}
}

func TestListShowsEveryItem(t *testing.T) {
	cfg, _ := fixture(t)
	out, err := run(t, "", "list", "-config", cfg)
	if err != nil || !strings.Contains(out, "TARGET") || !strings.Contains(out, "notes   file  a.txt  missing") {
		t.Fatalf("list: %v\n%s", err, out)
	}
	out, err = run(t, "", "list", "-config", cfg, "-json")
	if err != nil || !strings.Contains(out, `"name": "a.txt"`) || !strings.Contains(out, `"state": "missing"`) {
		t.Fatalf("list -json: %v\n%s", err, out)
	}
}

func TestListFiltersAndCaptureRefuses(t *testing.T) {
	cfg, _ := fixture(t)
	if out, err := run(t, "", "list", "-config", cfg, "-state", "in place"); err != nil || strings.Contains(out, "a.txt") {
		t.Fatalf("filtered list: %v\n%s", err, out)
	}
	if _, err := run(t, "", "capture", "-config", cfg); err == nil || !strings.Contains(err.Error(), "cannot capture") {
		t.Fatalf("capture localdir: %v", err)
	}
}

func TestCaptureWritesOnlyANewFileUnlessForced(t *testing.T) {
	out := filepath.Join(t.TempDir(), "Brewfile")
	data := []byte("brew \"git\"\n")
	tg := config.Target{Name: "brew"}
	var buf strings.Builder
	if err := writeCapture(tg, data, out, false, &buf); err != nil || !strings.Contains(buf.String(), "captured brew to "+out) {
		t.Fatalf("new file: %v %s", err, buf.String())
	}
	if err := writeCapture(tg, data, out, false, &buf); err == nil || !strings.Contains(err.Error(), "pass -force") {
		t.Fatalf("existing file: %v", err)
	}
	if err := writeCapture(tg, []byte("x\n"), out, true, &buf); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(out); string(got) != "x\n" {
		t.Fatalf("forced write %q", got)
	}
}

func TestForcedWriteTightensAnExistingWorldReadableFile(t *testing.T) {
	out := filepath.Join(t.TempDir(), "Brewfile")
	if err := os.WriteFile(out, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeFile(out, []byte("new\n"), true); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(out)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v, %v", info.Mode(), err)
	}
	if got, _ := os.ReadFile(out); string(got) != "new\n" {
		t.Fatalf("content %q", got)
	}
}

func TestAddWritesTheManifestOnly(t *testing.T) {
	root := t.TempDir()
	cfg := filepath.Join(root, name+".yaml")
	brewfile := filepath.Join(root, "Brewfile")
	_ = os.WriteFile(cfg, []byte("version: 1\ntargets:\n  - {name: pkgs, provider: packages, file: Brewfile}\n"), 0o600)
	_ = os.WriteFile(brewfile, []byte("# Tools\nbrew \"git\"\n"), 0o600)
	if _, err := run(t, "", "add", "-config", cfg, "-target", "pkgs", "cask:raycast"); err == nil {
		t.Fatal("added without -why")
	}
	out, err := run(t, "", "add", "-config", cfg, "-target", "pkgs", "-section", "Tools", "-why", "launcher", "cask:raycast")
	if err != nil || !strings.Contains(out, "plan -target pkgs") {
		t.Fatalf("add: %v\n%s", err, out)
	}
	if b, _ := os.ReadFile(brewfile); string(b) != "# Tools\nbrew \"git\"\ncask \"raycast\" # launcher\n" {
		t.Fatalf("Brewfile:\n%s", b)
	}
}

func TestAdocGroupsBySectionAndLinksHomepages(t *testing.T) {
	var b bytes.Buffer
	rows := []engine.TargetItems{
		{Target: "pkgs", Provider: "packages", Items: []engine.Item{
			{Name: "a/b", Kind: "tap"},
			{Name: "jq", Kind: "brew", Homepage: "https://jqlang.org", Version: "1.8", Note: manifest.Note{Section: "Data", Why: "JSON a|b"}},
			{Name: "old", Kind: "brew", State: engine.Extra},
		}},
		{Target: "home", Provider: "dotfiles", Items: []engine.Item{{Name: ".zshrc", Kind: "dotfile"}}},
		{Target: "runtimes", Provider: "tools", Items: []engine.Item{{Name: "go", Kind: "runtime", Desc: "requested latest"}, {Name: "go", Kind: "runtime", Version: "1.25"}}},
	}
	if err := writeAdoc(&b, rows); err != nil {
		t.Fatal(err)
	}
	out := b.String()
	for _, want := range []string{"== Data", "|https://jqlang.org[jq] |JSON a\\|b\n", "== runtimes", "|go |requested latest"} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q:\n%s", want, out)
		}
	}
	if strings.Count(out, "|go ") != 1 {
		t.Fatalf("go twice:\n%s", out)
	}
	for _, not := range []string{"a/b", "old", ".zshrc", "1.8", "1.25"} {
		if strings.Contains(out, not) {
			t.Fatalf("has %q:\n%s", not, out)
		}
	}
}

func TestSkipAddsListsAndUndoes(t *testing.T) {
	t.Setenv(config.EnvSkip, filepath.Join(t.TempDir(), "skip"))
	if out, err := run(t, "", "skip", "cask:zed", "brew:tmux"); err != nil || out != "brew:tmux\ncask:zed\n" {
		t.Fatalf("add: %v\n%s", err, out)
	}
	if out, err := run(t, "", "skip", "-undo", "-json", "cask:zed"); err != nil || out != "[\n  \"brew:tmux\"\n]\n" {
		t.Fatalf("undo: %v\n%s", err, out)
	}
	if _, err := run(t, "", "skip", "tmux"); err == nil {
		t.Fatal("a bare name was accepted")
	}
}

func TestInitWritesAStarterThatPlans(t *testing.T) {
	scratch := t.TempDir()
	t.Setenv(config.EnvSkip, filepath.Join(scratch, "skip"))
	t.Setenv(config.EnvProfiles, filepath.Join(scratch, "profiles"))
	dir := filepath.Join(scratch, "cfg")
	out, err := run(t, "", "init", "-profile", "everyday", "-role", "work", "-dir", dir, "-json")
	if err != nil || !strings.Contains(out, `"profiles": [`) || !strings.Contains(out, `"cask:ghostty"`) {
		t.Fatalf("init: %v\n%s", err, out)
	}
	if out, err := run(t, "", "profile"); err != nil || out != "everyday\nwork\n" {
		t.Fatalf("profile: %v\n%s", err, out)
	}
	if out, err := run(t, "", "validate", "-config", filepath.Join(dir, "zc-care.yaml")); err != nil {
		t.Fatalf("validate: %v\n%s", err, out)
	}
	if _, err := run(t, "", "init", "-profile", "everyday", "-dir", dir); err == nil {
		t.Fatal("init replaced a config without -force")
	}
	if out, err := run(t, "", "profile", "-clear", "-json"); err != nil || out != "[]\n" {
		t.Fatalf("clear: %v\n%s", err, out)
	}
	if out, err := run(t, "", "init", "-list"); err != nil || !strings.Contains(out, "developer") {
		t.Fatalf("list: %v\n%s", err, out)
	}
}
