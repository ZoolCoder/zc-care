package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseValid(t *testing.T) {
	cfg, err := Parse([]byte(`
version: 1
targets:
  - name: notes
    provider: localdir
    path: out/notes
    prune: true
    files:
      README.md: "hello\n"
`))
	if err != nil {
		t.Fatal(err)
	}
	if got := cfg.Names(); len(got) != 1 || got[0] != "notes" {
		t.Fatalf("names %v", got)
	}
	if tg, ok := cfg.Find("notes"); !ok || !tg.Prune || tg.Files["README.md"] != "hello\n" {
		t.Fatalf("target %+v", tg)
	}
}

func TestParseReportsEveryProblem(t *testing.T) {
	_, err := Parse([]byte(`
version: 2
targets:
  - name: Bad_Name
    provider: s3
  - name: escape
    provider: localdir
    files:
      ../escape: x
  - name: ok
    provider: localdir
    path: a
  - name: ok
    provider: localdir
    path: b
`))
	if err == nil {
		t.Fatal("invalid config accepted")
	}
	for _, want := range []string{"version is 2", "kebab-case", `provider "s3"`, "path is required for provider localdir", "inside the target path", "declared twice"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error lacks %q:\n%v", want, err)
		}
	}
}

func TestParseRefusesUnknownKeys(t *testing.T) {
	if _, err := Parse([]byte("version: 1\ntragets: []\n")); err == nil {
		t.Fatal("unknown key accepted")
	}
}

func TestLoadResolvesPathsAgainstTheFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tool.yaml")
	if err := os.WriteFile(path, []byte("version: 1\ntargets:\n  - {name: a, provider: localdir, path: out}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := cfg.Root(cfg.Targets[0]); got != filepath.Join(dir, "out") {
		t.Fatalf("root %q", got)
	}
	cfg, err = Load("-", strings.NewReader("version: 1\n"))
	if err != nil || cfg.Dir != "" {
		t.Fatalf("stdin: %+v %v", cfg, err)
	}
}

func TestParseChecksEachProvidersFields(t *testing.T) {
	_, err := Parse([]byte(`
version: 1
targets:
  - {name: pk, provider: packages}
  - {name: df, provider: dotfiles, mode: hardlink, file: x, upgrade: true}
  - {name: tl, provider: tools, source: home, wallpaper: w.png}
  - {name: dk, provider: desktop, file: x}
  - {name: da, provider: desktop, accent: teal}
  - {name: st, provider: settings}
  - {name: sv, provider: settings, defaults: {com.apple.dock: {persistent-apps: [a]}}, services: [x]}
  - {name: se, provider: services, agents: [job.txt]}
  - {name: sm, provider: services, agents: [a.timer]}
`))
	if err == nil {
		t.Fatal("invalid config accepted")
	}
	for _, want := range []string{
		"target pk: file is required",
		"target df: source is required", `mode "hardlink"`, "target df: file does nothing", "target df: upgrade does nothing",
		"target tl: file is required", "target tl: source does nothing", "target tl: wallpaper does nothing",
		"target dk: set wallpaper, screensaver or accent", "target dk: file does nothing",
		`target da: accent "teal" is not one of`,
		"target st: defaults is required", "target sv: com.apple.dock persistent-apps must be a bool, number or string",
		"target sv: services does nothing", `target se: agent "job.txt" must be a launchd .plist file`,
		`target sm: agent "a.timer" must be a launchd .plist file`,
	} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error lacks %q:\n%v", want, err)
		}
	}
}

func TestResolveExpandsHomeAndRelativePaths(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip(err)
	}
	dir, abs := t.TempDir(), t.TempDir()
	c := Config{Dir: dir}
	got := c.Resolve(Target{File: "packages/Brewfile", Source: "~/dots", Destination: abs})
	if got.File != filepath.Join(dir, "packages/Brewfile") || got.Source != filepath.Join(home, "dots") || got.Destination != abs {
		t.Fatalf("resolved %+v", got)
	}
}

func TestExampleConfigIsValid(t *testing.T) {
	if _, err := Load(filepath.Join("..", "..", "zc-care.example.yaml"), nil); err != nil {
		t.Fatal(err)
	}
}

func TestSkipListRoundTrips(t *testing.T) {
	path := filepath.Join(t.TempDir(), "zc", "skip")
	if got, err := ReadSkip(path); err != nil || got != nil {
		t.Fatalf("no file: %v, %v", got, err)
	}
	if err := WriteSkip(path, []string{"cask:zed", "brew:tmux", "cask:zed"}); err != nil {
		t.Fatal(err)
	}
	got, err := ReadSkip(path)
	if err != nil || strings.Join(got, ",") != "brew:tmux,cask:zed" {
		t.Fatalf("read %v, %v", got, err)
	}
}

func TestLoadHandsTheSkipListToEveryTarget(t *testing.T) {
	dir := t.TempDir()
	skip := filepath.Join(dir, "skip")
	t.Setenv(EnvSkip, skip)
	if err := os.WriteFile(skip, []byte("# mine\ncask:zed # not here\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfgPath := filepath.Join(dir, "zc.yaml")
	body := "version: 1\ntargets:\n  - name: brew\n    provider: packages\n    file: Brewfile\n"
	if err := os.WriteFile(cfgPath, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(cfgPath, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := cfg.Resolve(cfg.Targets[0]).Skip; len(got) != 1 || got[0] != "cask:zed" {
		t.Fatalf("skip %v", got)
	}
}

func TestProfilesAreKebabCaseAndRoundTrip(t *testing.T) {
	_, err := Parse([]byte("version: 1\ntargets:\n  - name: a\n    provider: localdir\n    path: a\n    profiles: [Work Mac]\n"))
	if err == nil || !strings.Contains(err.Error(), `profile "Work Mac" must be kebab-case`) {
		t.Fatalf("parse: %v", err)
	}
	path := filepath.Join(t.TempDir(), "profiles")
	if got, err := ReadProfiles(path); err != nil || got != nil {
		t.Fatalf("no file: %v %v", got, err)
	}
	if err := WriteProfiles(path, []string{"work", "developer", "work"}); err != nil {
		t.Fatal(err)
	}
	if got, err := ReadProfiles(path); err != nil || strings.Join(got, ",") != "developer,work" {
		t.Fatalf("read %v %v", got, err)
	}
}
