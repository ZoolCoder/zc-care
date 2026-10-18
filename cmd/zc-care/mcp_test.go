package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMCPPlanThenApplyByID(t *testing.T) {
	cfg, dir := fixture(t)
	s := mcpServer(t.TempDir())
	text, err := s.Call("plan", map[string]any{"config": cfg})
	if err != nil {
		t.Fatal(err)
	}
	var reply struct {
		ID   string `json:"plan_id"`
		Plan struct{ Changes int }
	}
	if err := json.Unmarshal([]byte(text), &reply); err != nil || reply.Plan.Changes != 1 {
		t.Fatalf("plan %q: %v", text, err)
	}
	if text, err = s.Call("apply", map[string]any{"plan_id": reply.ID}); err != nil || !strings.Contains(text, "applied and verified") {
		t.Fatalf("apply %q: %v", text, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "a.txt")); err != nil {
		t.Fatal(err)
	}
	if text, err := s.Call("status", map[string]any{"config": cfg}); err != nil || !strings.Contains(text, `"target": "notes"`) {
		t.Fatalf("status %q: %v", text, err)
	}
}

func TestMCPDeletionGoesToAPerson(t *testing.T) {
	cfg, dir := fixture(t)
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "stray.txt"), []byte("x"), 0o600)
	s := mcpServer(t.TempDir())
	text, err := s.Call("plan", map[string]any{"config": cfg})
	if err != nil {
		t.Fatal(err)
	}
	var reply struct {
		ID string `json:"plan_id"`
	}
	_ = json.Unmarshal([]byte(text), &reply)
	_, err = s.Call("apply", map[string]any{"plan_id": reply.ID})
	if err == nil || !strings.Contains(err.Error(), "Ask the user to run: "+name+" apply") {
		t.Fatalf("apply with deletion: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "stray.txt")); err != nil {
		t.Fatal("agent deleted a file")
	}
}

func TestMCPRefusesAStalePlanAndAuditsCalls(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	cfg, dir := fixture(t)
	state := t.TempDir()
	s := mcpServer(state)
	text, err := s.Call("plan", map[string]any{"config": cfg})
	if err != nil {
		t.Fatal(err)
	}
	var reply struct {
		ID string `json:"plan_id"`
	}
	_ = json.Unmarshal([]byte(text), &reply)
	old := time.Now().Add(-2 * planTTL)
	plan := filepath.Join(state, "plans", reply.ID+".plan")
	if err := os.Chtimes(plan, old, old); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Call("apply", map[string]any{"plan_id": reply.ID}); err == nil || !strings.Contains(err.Error(), "call plan again") {
		t.Fatalf("stale plan applied: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "a.txt")); !os.IsNotExist(err) {
		t.Fatal("stale plan changed the machine")
	}
	audit, _ := os.ReadFile(filepath.Join(state, "mcp-audit.jsonl"))
	if lines := strings.Count(string(audit), "\n"); lines != 2 || !strings.Contains(string(audit), `"detail":"apply -via=an agent`) {
		t.Fatalf("audit log:\n%s", audit)
	}
}

func TestMCPApplyIsRecordedAsAnAgent(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	cfg, _ := fixture(t)
	s := mcpServer(t.TempDir())
	text, _ := s.Call("plan", map[string]any{"config": cfg})
	var reply struct {
		ID string `json:"plan_id"`
	}
	_ = json.Unmarshal([]byte(text), &reply)
	if _, err := s.Call("apply", map[string]any{"plan_id": reply.ID}); err != nil {
		t.Fatal(err)
	}
	if text, err := s.Call("history", map[string]any{"n": 5}); err != nil || !strings.Contains(text, "applied from an agent") {
		t.Fatalf("history %q: %v", text, err)
	}
}

func TestMCPResourcesServeConfigAndManifests(t *testing.T) {
	root := t.TempDir()
	cfg := filepath.Join(root, name+".yaml")
	_ = os.WriteFile(cfg, []byte("version: 1\ntargets:\n  - {name: pkgs, provider: packages, file: Brewfile}\n"), 0o600)
	_ = os.WriteFile(filepath.Join(root, "Brewfile"), []byte("brew \"git\"\n"), 0o600)
	res := mcpResources(cfg)
	var uris []string
	for _, r := range res {
		uris = append(uris, r.URI)
	}
	if len(res) != 3 || uris[2] != name+"://manifest/pkgs" {
		t.Fatalf("resources %v", uris)
	}
	if text, err := res[2].Read(); err != nil || text != "brew \"git\"\n" {
		t.Fatalf("manifest %q: %v", text, err)
	}
}
