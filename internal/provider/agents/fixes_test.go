package agents

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSymlinkedSkillFolderIsCopied(t *testing.T) {
	p, target, home, _ := setup(t)
	real := filepath.Join(t.TempDir(), "review")
	write(t, filepath.Join(real, "SKILL.md"), "real\n")
	link := filepath.Join(filepath.Dir(target.File), "skills/linked")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	write(t, target.File, "clients: [claude]\nskills: [skills/linked]\n")
	actions, err := p.Plan(context.Background(), target)
	if err != nil || len(actions) != 1 {
		t.Fatalf("plan %v: %v", actions, err)
	}
	apply(t, actions)
	if got := read(t, filepath.Join(home, ".claude/skills/linked/SKILL.md")); got != "real\n" {
		t.Errorf("copied %q", got)
	}
}

func TestUnreadableRulesFileIsAnErrorNotACreate(t *testing.T) {
	p, target, home, _ := setup(t)
	write(t, target.File, "clients: [claude]\nrules: AGENTS.md\n")
	// A directory where the file should be reads as EISDIR, not as missing.
	if err := os.Remove(filepath.Join(home, ".claude/CLAUDE.md")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(home, ".claude/CLAUDE.md"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Plan(context.Background(), target); err == nil || !strings.Contains(err.Error(), "read ~/.claude/CLAUDE.md") {
		t.Fatalf("err %v", err)
	}
}

func TestNullJSONDoesNotPanic(t *testing.T) {
	for _, body := range []string{`null`, `{"mcpServers": null}`} {
		p, target, home, _ := setup(t)
		write(t, target.File, "clients: [claude]\nservers:\n  r: {url: \"https://x.example\"}\n")
		write(t, filepath.Join(home, ".claude.json"), body)
		actions, err := p.Plan(context.Background(), target)
		if err != nil || len(actions) != 1 {
			t.Fatalf("%s: plan %v: %v", body, actions, err)
		}
		apply(t, actions)
		if got := read(t, filepath.Join(home, ".claude.json")); !strings.Contains(got, `"https://x.example"`) {
			t.Errorf("%s: %s", body, got)
		}
	}
}

func TestSecretsFileIsMadePrivate(t *testing.T) {
	p, target, home, _ := withSecrets(t)
	path := filepath.Join(home, ".claude.json")
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	actions, _ := p.Plan(context.Background(), target)
	apply(t, actions)
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", info.Mode().Perm())
	}
}

func TestPlainFileKeepsItsMode(t *testing.T) {
	p, target, home, _ := setup(t)
	write(t, target.File, "clients: [claude]\nservers:\n  r: {url: \"https://x.example\"}\n")
	path := filepath.Join(home, ".claude.json")
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	actions, _ := p.Plan(context.Background(), target)
	apply(t, actions)
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o644 {
		t.Errorf("mode %v", info.Mode().Perm())
	}
}

func TestWriteSkippedWhenEntryAlreadyThere(t *testing.T) {
	p, target, home, _ := setup(t)
	write(t, target.File, "clients: [claude]\nservers:\n  r: {url: \"https://x.example\"}\n")
	path := filepath.Join(home, ".claude.json")
	actions, _ := p.Plan(context.Background(), target)

	// The agent wrote the same entry after the plan: nothing to write.
	write(t, path, `{"mcpServers":{"r":{"type":"http","url":"https://x.example"}}}`)
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	apply(t, actions)
	if info, _ := os.Stat(path); !info.ModTime().Equal(old) {
		t.Error("file was rewritten")
	}
}

func TestFileChangedUnderUsIsRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "c.json")
	write(t, path, `{"a":1}`)
	_, seen, err := readStamped(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := unchanged(path, seen); err != nil {
		t.Fatalf("untouched file: %v", err)
	}
	write(t, path, `{"a":1,"b":2}`)
	if err := unchanged(path, seen); err == nil || !strings.Contains(err.Error(), "re-run") {
		t.Errorf("err %v", err)
	}
}

func TestBeginMarkerWithoutEndIsCorrupt(t *testing.T) {
	p, target, home, _ := setup(t)
	write(t, target.File, "clients: [claude]\nrules: AGENTS.md\n")
	write(t, filepath.Join(home, ".claude/CLAUDE.md"), "x\n<!-- zc-care agents: begin -->\nhalf\n")
	if _, err := p.Plan(context.Background(), target); err == nil || !strings.Contains(err.Error(), "no matching end marker") {
		t.Fatalf("err %v", err)
	}
	write(t, target.File, "clients: [codex]\nservers:\n  r: {url: \"https://x.example\"}\n")
	write(t, filepath.Join(home, ".codex/config.toml"), codexBegin+"\n")
	if _, err := p.Plan(context.Background(), target); err == nil || !strings.Contains(err.Error(), "no matching end marker") {
		t.Fatalf("codex err %v", err)
	}
}
