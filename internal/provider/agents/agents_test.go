package agents

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
	"github.com/zoolcoder/zc-care/internal/sh"
)

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// setup writes a manifest and a home holding what the user already had.
func setup(t *testing.T) (Provider, config.Target, string, *sh.Fake) {
	t.Helper()
	src, home := t.TempDir(), t.TempDir()
	write(t, filepath.Join(src, "agents.yaml"), `
servers:
  docs:
    command: npx
    args: [-y, "docs-mcp@1.2.0"]
    env: {DOCS_TOKEN: "${DOCS_TOKEN}"}
  remote:
    url: https://mcp.example.com/mcp
rules: AGENTS.md
skills: [skills/review]
models: [qwen3:8b, nomic-embed-text]
`)
	write(t, filepath.Join(src, "AGENTS.md"), "Be brief.\n")
	write(t, filepath.Join(src, "skills/review/SKILL.md"), "---\nname: review\n---\n")
	write(t, filepath.Join(home, ".claude.json"), `{"numStartups": 7, "mcpServers": {"mine": {"command": "x"}}}`)
	write(t, filepath.Join(home, ".claude/CLAUDE.md"), "# Mine\n")
	write(t, filepath.Join(home, ".codex/config.toml"), "model = \"o4\"\n")
	f := &sh.Fake{Programs: []string{"ollama"}, Out: map[string]string{
		"ollama list": "NAME                       ID   SIZE  MODIFIED\nnomic-embed-text:latest    a    274M  1 day ago\n",
	}}
	return Provider{r: f, home: home}, config.Target{Name: "ai", Provider: "agents", File: filepath.Join(src, "agents.yaml")}, home, f
}

func apply(t *testing.T, actions []plan.Action) {
	t.Helper()
	for _, a := range actions {
		if a.Do == nil {
			t.Fatalf("manual action %+v", a)
		}
		if err := a.Do(context.Background()); err != nil {
			t.Fatalf("%s: %v", a.Resource, err)
		}
	}
}

func TestPlanWritesEveryClientAndConverges(t *testing.T) {
	p, target, home, f := setup(t)
	ctx := context.Background()
	actions, err := p.Plan(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	// 2 servers x 4 clients, rules for claude, codex and gemini, the skill
	// for claude and codex, and one missing model.
	if len(actions) != 8+3+2+1 {
		for _, a := range actions {
			t.Log(a.Op, a.Resource)
		}
		t.Fatalf("%d actions", len(actions))
	}
	for _, a := range actions {
		if a.Op == plan.OpDelete {
			t.Fatalf("deletes: %+v", a)
		}
	}
	apply(t, actions)

	claude := read(t, filepath.Join(home, ".claude.json"))
	for _, want := range []string{`"numStartups": 7`, `"mine"`, `"type": "stdio"`, `"DOCS_TOKEN": "${DOCS_TOKEN}"`, `"type": "http"`} {
		if !strings.Contains(claude, want) {
			t.Errorf(".claude.json lacks %s:\n%s", want, claude)
		}
	}
	if s := read(t, filepath.Join(home, ".gemini/settings.json")); !strings.Contains(s, `"httpUrl": "https://mcp.example.com/mcp"`) {
		t.Errorf("gemini:\n%s", s)
	}
	codex := read(t, filepath.Join(home, ".codex/config.toml"))
	if !strings.HasPrefix(codex, "model = \"o4\"\n\n"+codexBegin) || !strings.Contains(codex, `env_vars = ["DOCS_TOKEN"]`) {
		t.Errorf("codex:\n%s", codex)
	}
	if s := read(t, filepath.Join(home, ".claude/CLAUDE.md")); !strings.HasPrefix(s, "# Mine\n\n<!-- zc-care agents: begin -->\nBe brief.\n") {
		t.Errorf("rules:\n%s", s)
	}
	if read(t, filepath.Join(home, ".codex/skills/review/SKILL.md")) == "" {
		t.Error("skill not copied")
	}
	if !strings.Contains(strings.Join(f.Ran, "\n"), "ollama pull -- qwen3:8b") {
		t.Errorf("ran %v", f.Ran)
	}

	f.Out["ollama list"] += "qwen3:8b  b  5G  now\n"
	if actions, err := p.Plan(ctx, target); err != nil || len(actions) != 0 {
		t.Fatalf("second plan %v: %v", actions, err)
	}
	m, _ := p.Measure(ctx, target)
	if m.InPlace != m.Declared || m.Declared != 15 {
		t.Errorf("measure %+v", m)
	}
}

func TestChangedServerIsAnUpdateAndCodexConflictIsManual(t *testing.T) {
	p, target, home, _ := setup(t)
	ctx := context.Background()
	actions, _ := p.Plan(ctx, target)
	apply(t, actions)
	write(t, filepath.Join(home, ".cursor/mcp.json"), `{"mcpServers":{"docs":{"command":"npx","args":["-y","docs-mcp@1.0.0"]},"remote":{"url":"https://mcp.example.com/mcp"}}}`)
	write(t, filepath.Join(home, ".codex/config.toml"), "[mcp_servers.docs]\ncommand = \"docs\"\n")
	items, err := p.Items(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, it := range items {
		got[it.Name+"/"+it.App] = it.State
	}
	if got["docs/cursor"] != provider.Differs || got["docs/codex"] != provider.Manual || got["remote/codex"] != provider.Missing {
		t.Fatalf("items %v", got)
	}
}

func TestManifestIsChecked(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "a.yaml"), "clients: [vim]\nservers:\n  x: {command: a, url: b}\n")
	_, err := Load(filepath.Join(dir, "a.yaml"))
	if err == nil || !strings.Contains(err.Error(), `client "vim"`) || !strings.Contains(err.Error(), "server x") {
		t.Fatalf("err %v", err)
	}
	write(t, filepath.Join(dir, "b.yaml"), "rules: r.md\n")
	if m, err := Load(filepath.Join(dir, "b.yaml")); err != nil || len(m.Clients) != 4 || m.Rules != filepath.Join(dir, "r.md") {
		t.Fatalf("%+v %v", m, err)
	}
}
