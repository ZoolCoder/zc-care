package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const snapshotA = `{"version":1,"host":"mini","macos":"15.1","date":"2026-10-20T08:00:00Z","targets":[
 {"name":"packages","provider":"packages","items":[
  {"kind":"brew","name":"git","state":"in place","version":"2.45.0"},
  {"kind":"brew","name":"tmux","state":"in place","version":"3.5"},
  {"kind":"cask","name":"ghostty","state":"missing"}]},
 {"name":"mac","provider":"settings","items":[
  {"kind":"setting","name":"com.apple.dock tilesize","state":"in place","version":"48"}]},
 {"name":"only-a","provider":"services","items":[{"kind":"brew","name":"redis","state":"in place"}]}]}`

const snapshotB = `{"version":1,"host":"air","macos":"15.2","date":"2026-10-21T08:00:00Z","targets":[
 {"name":"packages","provider":"packages","items":[
  {"kind":"brew","name":"git","state":"outdated","version":"2.46.0"},
  {"kind":"brew","name":"tmux","state":"in place","version":"3.5"},
  {"kind":"cask","name":"ghostty","state":"in place","version":"1.0"}]},
 {"name":"mac","provider":"settings","items":[
  {"kind":"setting","name":"com.apple.dock tilesize","state":"in place","version":"48"}]}]}`

func writeSnapshots(t *testing.T, bodies ...string) []string {
	t.Helper()
	dir := t.TempDir()
	var paths []string
	for i, b := range bodies {
		p := filepath.Join(dir, string(rune('a'+i))+".json")
		if err := os.WriteFile(p, []byte(b), 0o600); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, p)
	}
	return paths
}

func TestDiffGroupsByTarget(t *testing.T) {
	p := writeSnapshots(t, snapshotA, snapshotB)
	out, err := run(t, "", "diff", p[0], p[1])
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"A " + p[0] + ": mini, macOS 15.1", "B " + p[1] + ": air, macOS 15.2",
		"packages\n  only in B\n    cask:ghostty  1.0\n  different\n    brew:git  2.45.0 -> 2.46.0\n",
		"only-a\n  only in A\n    brew:redis  in place\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("diff lacks %q:\n%s", want, out)
		}
	}
	// Equal targets and equal items stay out.
	if strings.Contains(out, "tmux") || strings.Contains(out, "\nmac\n") {
		t.Errorf("diff lists what matches:\n%s", out)
	}
}

func TestDiffJSONAndNoDifferences(t *testing.T) {
	p := writeSnapshots(t, snapshotA, snapshotB)
	out, err := run(t, "", "diff", "-json", p[0], p[1])
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Targets []targetDiff `json:"targets"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil || len(got.Targets) != 2 || got.Targets[0].Target != "packages" {
		t.Fatalf("json %v: %s", err, out)
	}
	if out, err = run(t, "", "diff", p[0], p[0]); err != nil || !strings.Contains(out, "no differences") {
		t.Fatalf("self diff %v:\n%s", err, out)
	}
}

func TestDiffRefusesWhatIsNotASnapshot(t *testing.T) {
	p := writeSnapshots(t, `{"version":9}`, `nope`)
	if _, err := run(t, "", "diff", p[0], p[0]); err == nil || !strings.Contains(err.Error(), "version 9") {
		t.Errorf("err %v", err)
	}
	if _, err := run(t, "", "diff", p[1], p[0]); err == nil || !strings.Contains(err.Error(), "not a snapshot") {
		t.Errorf("err %v", err)
	}
	if _, err := run(t, "", "diff"); err == nil {
		t.Error("diff with no file")
	}
}

func TestExportHoldsHashesNotContentAndDiffsAgainstThisMac(t *testing.T) {
	cfg, dir := fixture(t)
	if _, err := run(t, "", "apply", "-config", cfg); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "mac.json")
	if out, err := run(t, "", "export", "-config", cfg, "-o", file); err != nil || !strings.Contains(out, "exported 1 target(s)") {
		t.Fatalf("export %v: %s", err, out)
	}
	b, _ := os.ReadFile(file)
	sum := sha256.Sum256([]byte("A\n"))
	if !strings.Contains(string(b), hex.EncodeToString(sum[:])) {
		t.Errorf("no hash in:\n%s", b)
	}
	if strings.Contains(string(b), `"A\n"`) {
		t.Errorf("content in:\n%s", b)
	}
	if info, _ := os.Stat(file); info.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", info.Mode())
	}

	if out, err := run(t, "", "diff", "-config", cfg, file); err != nil || !strings.Contains(out, "no differences") {
		t.Fatalf("live diff %v:\n%s", err, out)
	}
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("edited\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := run(t, "", "diff", "-config", cfg, file)
	if err != nil || !strings.Contains(out, "notes\n  different\n    file:a.txt  sha256:") {
		t.Fatalf("edited diff %v:\n%s", err, out)
	}
}

func TestValidateFlagsMalformedKeychainRef(t *testing.T) {
	root := t.TempDir()
	cfg := filepath.Join(root, name+".yaml")
	body := "version: 1\ntargets:\n  - name: ai\n    provider: agents\n    file: agents.yaml\n"
	if err := os.WriteFile(cfg, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	manifest := filepath.Join(root, "agents.yaml")
	if err := os.WriteFile(manifest, []byte("servers:\n  x:\n    command: a\n    env: {T: \"${keychain:}\"}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := run(t, "", "validate", "-config", cfg); err == nil || !strings.Contains(err.Error(), "malformed secret reference") {
		t.Fatalf("err %v", err)
	}
	if err := os.WriteFile(manifest, []byte("servers:\n  x:\n    command: a\n    env: {T: \"${keychain:svc}\"}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := run(t, "", "validate", "-config", cfg); err != nil {
		t.Fatal(err)
	}
}
