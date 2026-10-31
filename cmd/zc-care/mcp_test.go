package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/zoolcoder/zc-care/internal/plan"
)

func TestMCPPlanThenApplyByID(t *testing.T) {
	cfg, dir := fixture(t)
	t.Setenv(envConfig, cfg)
	s := mcpServer(t.TempDir())
	text, err := s.Call("plan", map[string]any{})
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
	if text, err := s.Call("status", map[string]any{}); err != nil || !strings.Contains(text, `"target": "notes"`) {
		t.Fatalf("status %q: %v", text, err)
	}
}

func TestMCPDeletionGoesToAPerson(t *testing.T) {
	cfg, dir := fixture(t)
	t.Setenv(envConfig, cfg)
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "stray.txt"), []byte("x"), 0o600)
	s := mcpServer(t.TempDir())
	text, err := s.Call("plan", map[string]any{})
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
	t.Setenv(envConfig, cfg)
	state := t.TempDir()
	s := mcpServer(state)
	text, err := s.Call("plan", map[string]any{})
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
	t.Setenv(envConfig, cfg)
	s := mcpServer(t.TempDir())
	text, _ := s.Call("plan", map[string]any{})
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

func TestMCPResourcesServeNoHiddenText(t *testing.T) {
	root := t.TempDir()
	cfg := filepath.Join(root, name+".yaml")
	_ = os.WriteFile(cfg, []byte("version: 1\n# \u202ehidden\ntargets:\n  - {name: pkgs, provider: packages, file: Brewfile}\n"), 0o600)
	_ = os.WriteFile(filepath.Join(root, "Brewfile"), []byte("brew \"git\" # why \U000e0041\x1b[2K\n"), 0o600)
	for _, r := range mcpResources(cfg) {
		text, err := r.Read()
		if err != nil {
			t.Fatalf("%s: %v", r.URI, err)
		}
		if strings.ContainsFunc(text, plan.Unsafe) {
			t.Fatalf("%s served %q", r.URI, text)
		}
	}
}

func TestMCPApplySpendsThePlanAndReturnsADigest(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	cfg, _ := fixture(t)
	t.Setenv(envConfig, cfg)
	state := t.TempDir()
	s := mcpServer(state)
	text, _ := s.Call("plan", map[string]any{})
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
	for _, name := range []string{
		"cloud/AGENTS.md", "codex/AGENTS.md", "copilot/copilot-instructions.md",
		"cursor/zc-care.mdc", "gemini/GEMINI.md",
	} {
		f := filepath.Join(dir, name)
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		_, rest, _ := strings.Cut(string(b), "<!-- common:start -->\n")
		block, _, ok := strings.Cut(rest, "<!-- common:end -->")
		if !ok || block != string(common) {
			t.Errorf("%s differs from COMMON.md: run sh plugin/adapters/gen.sh", f)
		}
	}
}

func TestMCPValidateIsStructured(t *testing.T) {
	cfg, _ := fixture(t)
	t.Setenv(envConfig, cfg)
	s := mcpServer(t.TempDir())
	var reply struct {
		Config  string
		Targets []string
		Valid   bool
		Errors  []string
	}
	text, err := s.Call("validate", map[string]any{})
	if err != nil || json.Unmarshal([]byte(text), &reply) != nil || !reply.Valid || len(reply.Targets) != 1 || reply.Targets[0] != "notes" {
		t.Fatalf("validate %q: %v", text, err)
	}
	bad := filepath.Join(t.TempDir(), "bad.yaml")
	_ = os.WriteFile(bad, []byte("version: 1\ntargets: [\n"), 0o600)
	t.Setenv(envConfig, bad)
	text, err = s.Call("validate", map[string]any{})
	reply.Valid = true
	if err != nil || json.Unmarshal([]byte(text), &reply) != nil || reply.Valid || len(reply.Errors) == 0 {
		t.Fatalf("validate bad %q: %v", text, err)
	}
}

func planID(t *testing.T, s interface {
	Call(string, map[string]any) (string, error)
}) string {
	t.Helper()
	text, err := s.Call("plan", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	var reply struct {
		ID string `json:"plan_id"`
	}
	if err := json.Unmarshal([]byte(text), &reply); err != nil || reply.ID == "" {
		t.Fatalf("plan %q: %v", text, err)
	}
	return reply.ID
}

func TestMCPToolsTakeNoConfigAndUndoIsAbsent(t *testing.T) {
	s := mcpServer(t.TempDir())
	for _, tool := range s.Tools {
		if tool.Name == "undo" {
			t.Fatal("undo is an MCP tool")
		}
		for _, p := range tool.Props {
			if p.Name == "config" || p.Flag == "config" {
				t.Errorf("tool %s takes a config argument", tool.Name)
			}
		}
	}
}

func TestMCPIgnoresAnAgentConfig(t *testing.T) {
	real, _ := fixture(t)
	other, _ := fixture(t)
	t.Setenv(envConfig, real)
	s := mcpServer(t.TempDir())
	if _, err := s.Call("plan", map[string]any{"config": other}); err != nil {
		t.Fatal(err)
	}
	flags, _ := filepath.Glob(filepath.Join(s.StateDir, "plans", "*.flags.json"))
	if len(flags) != 1 {
		t.Fatalf("flags files %v", flags)
	}
	if b, _ := os.ReadFile(flags[0]); strings.Contains(string(b), "config") {
		t.Fatalf("saved flags carry a config: %s", b)
	}
}

func TestMCPRefusesASavedPlanFromAnotherConfig(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	cfg, dir := fixture(t)
	other, _ := fixture(t)
	t.Setenv(envConfig, cfg)
	s := mcpServer(t.TempDir())
	id := planID(t, s)
	flags := filepath.Join(s.StateDir, "plans", id+".flags.json")
	foreign, _ := json.Marshal(map[string][]string{"flags": {"-config=" + other}})
	if err := os.WriteFile(flags, foreign, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Call("apply", map[string]any{"plan_id": id}); err == nil || !strings.Contains(err.Error(), "another config") {
		t.Fatalf("foreign plan applied: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "a.txt")); !os.IsNotExist(err) {
		t.Fatal("foreign plan changed the machine")
	}
}

func TestMCPRemoveReturnsACommandNotAPlanID(t *testing.T) {
	cfg, brewfile := packagesFixture(t)
	t.Setenv(envConfig, cfg)
	s := mcpServer(t.TempDir())
	text, err := s.Call("remove", map[string]any{"target": "pkgs", "item": "brew:htop"})
	if err != nil {
		t.Fatal(err)
	}
	var reply struct {
		Appliable bool
		Command   string
		PlanID    string `json:"plan_id"`
	}
	if err := json.Unmarshal([]byte(text), &reply); err != nil || reply.Appliable || reply.PlanID != "" {
		t.Fatalf("remove %q: %v", text, err)
	}
	if want := name + " remove -target pkgs -config " + shellQuote(cfg) + " brew:htop"; reply.Command != want {
		t.Fatalf("command %q, want %q", reply.Command, want)
	}
	unchanged(t, brewfile)
	if plans, _ := filepath.Glob(filepath.Join(s.StateDir, "plans", "*")); len(plans) != 0 {
		t.Fatalf("remove saved a plan: %v", plans)
	}
}

func TestMCPConcurrentAppliesOfOnePlanRunOnce(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	cfg, _ := fixture(t)
	t.Setenv(envConfig, cfg)
	state := t.TempDir()
	id := planID(t, mcpServer(state))
	const callers = 6
	var wg sync.WaitGroup
	results := make(chan error, callers)
	for range callers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := mcpServer(state).Call("apply", map[string]any{"plan_id": id})
			results <- err
		}()
	}
	wg.Wait()
	close(results)
	won := 0
	for err := range results {
		if err == nil {
			won++
		}
	}
	if won != 1 {
		t.Fatalf("%d applies of one plan succeeded, want 1", won)
	}
}

func TestMCPClaimedPlanFailsASecondApply(t *testing.T) {
	state := t.TempDir()
	plans := filepath.Join(state, "plans")
	_ = os.MkdirAll(plans, 0o700)
	file := filepath.Join(plans, "0123456789abcdef.plan")
	_ = os.WriteFile(file+".running", []byte("{}"), 0o600)
	err := runSpent(state, func([]string, io.Reader, io.Writer, io.Writer) error {
		t.Fatal("ran a claimed plan")
		return nil
	}, []string{"apply", file}, nil, io.Discard, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "plan already applied or running") {
		t.Fatalf("second claim: %v", err)
	}
}

func TestMCPApplyRefusedBeforeRunningKeepsThePlan(t *testing.T) {
	state := t.TempDir()
	plans := filepath.Join(state, "plans")
	_ = os.MkdirAll(plans, 0o700)
	file := filepath.Join(plans, "0123456789abcdef.plan")
	_ = os.WriteFile(file, []byte("{}"), 0o600)
	refuse := func([]string, io.Reader, io.Writer, io.Writer) error { return errManualOnly }
	if err := runSpent(state, refuse, []string{"apply", file}, nil, io.Discard, io.Discard); !errors.Is(err, errManualOnly) {
		t.Fatalf("err %v", err)
	}
	if _, err := os.Stat(file); err != nil {
		t.Fatal("a refusal spent the plan")
	}
	failed := func([]string, io.Reader, io.Writer, io.Writer) error { return errors.New("brew failed") }
	_ = runSpent(state, failed, []string{"apply", file}, nil, io.Discard, io.Discard)
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Fatal("an apply that ran left the plan live")
	}
}

func TestMCPShellQuotesTheTerminalCommand(t *testing.T) {
	cancelled := mcpServer(t.TempDir()).Cancelled
	err := cancelled(errCancelled, []string{"apply", "-via=an agent", "-target=a b; touch x", "/state/plans/x.plan"})
	if err == nil || !strings.Contains(err.Error(), "apply '-target=a b; touch x' /state/plans/x.plan") {
		t.Fatalf("command not quoted: %v", err)
	}
}

func TestMCPStripsControlCharacters(t *testing.T) {
	run := sanitized(func(_ []string, _ io.Reader, stdout, _ io.Writer) error {
		_, _ = io.WriteString(stdout, `{"actions":[{"detail":"Fast\u001b[2J helper\nline\u007f"}]}`)
		return errors.New("bad \x1b[31m")
	})
	var out bytes.Buffer
	err := run(nil, nil, &out, io.Discard)
	if strings.Contains(out.String(), "u001b") || strings.Contains(out.String(), "u007f") {
		t.Fatalf("control characters survived: %q", out.String())
	}
	var doc struct{ Actions []struct{ Detail string } }
	if json.Unmarshal(out.Bytes(), &doc) != nil || doc.Actions[0].Detail != "Fast[2J helper\nline" {
		t.Fatalf("detail %q", out.String())
	}
	if err == nil || strings.Contains(err.Error(), "\x1b") {
		t.Fatalf("error %q", err)
	}
	if got := plan.Clean("a\tb\r\n\x00c"); got != "a\tb\nc" {
		t.Fatalf("plain text %q", got)
	}
	if got := plan.Clean("safe\u009b2J\u202egnp.exe\u200b\u2066 caf\u00e9"); got != "safe2Jgnp.exe caf\u00e9" {
		t.Fatalf("hidden characters %q", got)
	}
}
