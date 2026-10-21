package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const removeBrewfile = "# Tools\nbrew \"htop\" # processes\n"

// packagesFixture is a config with one Brewfile target and the Brewfile's path.
func packagesFixture(t *testing.T) (cfg, brewfile string) {
	t.Helper()
	root := t.TempDir()
	cfg, brewfile = filepath.Join(root, name+".yaml"), filepath.Join(root, "Brewfile")
	if err := os.WriteFile(cfg, []byte("version: 1\ntargets:\n  - {name: pkgs, provider: packages, file: Brewfile}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(brewfile, []byte(removeBrewfile), 0o600); err != nil {
		t.Fatal(err)
	}
	return cfg, brewfile
}

func unchanged(t *testing.T, brewfile string) {
	t.Helper()
	if b, _ := os.ReadFile(brewfile); string(b) != removeBrewfile {
		t.Fatalf("Brewfile changed:\n%s", b)
	}
}

func TestPlanRemoveShowsADeleteAndChangesNothing(t *testing.T) {
	cfg, brewfile := packagesFixture(t)
	out, err := run(t, "", "plan", "-config", cfg, "-target", "pkgs", "-remove", "brew:htop")
	if err != nil || !strings.Contains(out, "DELETE  pkgs  brew:htop") {
		t.Fatalf("plan: %v\n%s", err, out)
	}
	unchanged(t, brewfile)
	if _, err := run(t, "", "plan", "-config", cfg, "-target", "pkgs", "-remove", "brew:--force"); err == nil {
		t.Fatal("a flag planned as a package")
	}
}

func TestRemoveAsksBeforeUninstalling(t *testing.T) {
	cfg, brewfile := packagesFixture(t)
	out, err := run(t, "no\n", "remove", "-config", cfg, "-target", "pkgs", "brew:htop")
	if !errors.Is(err, errCancelled) || !strings.Contains(out, "DELETE  pkgs  brew:htop") {
		t.Fatalf("remove: %v\n%s", err, out)
	}
	unchanged(t, brewfile)
}

func TestSavedRemovalPlanAppliesOnlyToItsItem(t *testing.T) {
	cfg, brewfile := packagesFixture(t)
	saved := filepath.Join(t.TempDir(), "plan.json")
	if _, err := run(t, "", "plan", "-config", cfg, "-target", "pkgs", "-remove", "brew:htop", "-out", saved); err != nil {
		t.Fatal(err)
	}
	if _, err := run(t, "no\n", "apply", "-config", cfg, "-remove", "brew:wget", saved); err == nil || !strings.Contains(err.Error(), "saved for -remove") {
		t.Fatalf("other item: %v", err)
	}
	// Without -remove the plan's own item is used, and still needs a person.
	if _, err := run(t, "no\n", "apply", "-config", cfg, saved); !errors.Is(err, errCancelled) {
		t.Fatalf("apply: %v", err)
	}
	unchanged(t, brewfile)
}

func TestMCPRemoveOnlyPlansAndTheTerminalAppliesIt(t *testing.T) {
	cfg, brewfile := packagesFixture(t)
	s := mcpServer(t.TempDir())
	text, err := s.Call("remove", map[string]any{"config": cfg, "target": "pkgs", "item": "brew:htop"})
	if err != nil {
		t.Fatal(err)
	}
	var reply struct {
		ID   string `json:"plan_id"`
		Plan struct {
			Actions []struct {
				Op          string
				Resource    string
				Destructive bool
			}
		}
	}
	if err := json.Unmarshal([]byte(text), &reply); err != nil || len(reply.Plan.Actions) != 1 ||
		reply.Plan.Actions[0].Op != "DELETE" || !reply.Plan.Actions[0].Destructive {
		t.Fatalf("remove %q: %v", text, err)
	}
	unchanged(t, brewfile)
	_, err = s.Call("apply", map[string]any{"plan_id": reply.ID})
	if err == nil || !strings.Contains(err.Error(), "Ask the user to run: "+name+" apply") || !strings.Contains(err.Error(), "-remove=brew:htop") {
		t.Fatalf("apply of a removal: %v", err)
	}
	unchanged(t, brewfile)
}
