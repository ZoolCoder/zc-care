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

func TestMCPApplySpendsThePlanAndReturnsADigest(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	cfg, _ := fixture(t)
	state := t.TempDir()
	s := mcpServer(state)
	text, _ := s.Call("plan", map[string]any{"config": cfg})
	var reply struct {
		ID string `json:"plan_id"`
	}
	_ = json.Unmarshal([]byte(text), &reply)
	text, err := s.Call("apply", map[string]any{"plan_id": reply.ID})
	if err != nil || !strings.Contains(text, "digest: applied 1 CREATE") {
		t.Fatalf("apply %q: %v", text, err)
	}
	for _, ext := range []string{".plan", ".flags.json"} {
		if _, err := os.Stat(filepath.Join(state, "plans", reply.ID+ext)); !os.IsNotExist(err) {
			t.Fatalf("%s survived the apply", ext)
		}
	}
	if _, err := s.Call("apply", map[string]any{"plan_id": reply.ID}); err == nil || !strings.Contains(err.Error(), "call the plan tool first") {
		t.Fatalf("plan_id reused: %v", err)
	}
}

func TestMCPAddIgnoresAnAgentConfigAndReturnsJSON(t *testing.T) {
	real, brewfile := packagesFixture(t)
	other, otherBrewfile := packagesFixture(t)
	t.Setenv(envConfig, real)
	s := mcpServer(t.TempDir())
	text, err := s.Call("add", map[string]any{"config": other, "target": "pkgs", "item": "brew:jq", "why": "parses JSON", "section": "Tools"})
	if err != nil {
		t.Fatal(err)
	}
	var reply struct{ File, Item, Section string }
	if err := json.Unmarshal([]byte(text), &reply); err != nil || reply.File != brewfile || reply.Item != "brew:jq" || reply.Section != "Tools" {
		t.Fatalf("add %q: %v", text, err)
	}
	if b, _ := os.ReadFile(brewfile); !strings.Contains(string(b), "jq") {
		t.Fatalf("default config not edited:\n%s", b)
	}
	unchanged(t, otherBrewfile)
}

// Every adapter carries plugin/adapters/COMMON.md between its markers; run
// plugin/adapters/gen.sh after editing it.
func TestAdaptersCarryCommon(t *testing.T) {
	dir := filepath.Join("..", "..", "plugin", "adapters")
	common, err := os.ReadFile(filepath.Join(dir, "COMMON.md"))
	if err != nil {
		t.Fatal(err)
	}
	files, _ := filepath.Glob(filepath.Join(dir, "*", "*"))
	if len(files) != 5 {
		t.Fatalf("adapters %v", files)
	}
	for _, f := range files {
		b, _ := os.ReadFile(f)
		_, rest, _ := strings.Cut(string(b), "<!-- common:start -->\n")
		block, _, ok := strings.Cut(rest, "<!-- common:end -->")
		if !ok || block != string(common) {
			t.Errorf("%s differs from COMMON.md: run sh plugin/adapters/gen.sh", f)
		}
	}
}

func TestMCPValidateIsStructured(t *testing.T) {
	cfg, _ := fixture(t)
	s := mcpServer(t.TempDir())
	var reply struct {
		Config  string
		Targets []string
		Valid   bool
		Errors  []string
	}
	text, err := s.Call("validate", map[string]any{"config": cfg})
	if err != nil || json.Unmarshal([]byte(text), &reply) != nil || !reply.Valid || len(reply.Targets) != 1 || reply.Targets[0] != "notes" {
		t.Fatalf("validate %q: %v", text, err)
	}
	bad := filepath.Join(t.TempDir(), "bad.yaml")
	_ = os.WriteFile(bad, []byte("version: 1\ntargets: [\n"), 0o600)
	text, err = s.Call("validate", map[string]any{"config": bad})
	reply.Valid = true
	if err != nil || json.Unmarshal([]byte(text), &reply) != nil || reply.Valid || len(reply.Errors) == 0 {
		t.Fatalf("validate bad %q: %v", text, err)
	}
}
