package tools

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
	"github.com/zoolcoder/zc-care/internal/sh"
)

func setup(t *testing.T) (config.Target, string) {
	dir := t.TempDir()
	file := filepath.Join(dir, "mise.toml")
	if err := os.WriteFile(file, []byte("[tools]\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return config.Target{Name: "rt", Provider: "tools", File: file}, "mise ls --json -C " + dir
}

func TestPlanInstallsMissingVersionsFromThisFileOnly(t *testing.T) {
	tg, ls := setup(t)
	other := filepath.Join(t.TempDir(), "config.toml")
	if err := os.WriteFile(other, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	r := &sh.Fake{Programs: []string{"mise"}, Out: map[string]string{ls: `{
		"node": [{"version": "22.11.0", "requested_version": "lts", "installed": true, "source": {"path": ` + strconv.Quote(tg.File) + `}}],
		"java": [
			{"version": "temurin-25.0.1", "requested_version": "temurin-25", "installed": false, "source": {"path": ` + strconv.Quote(tg.File) + `}},
			{"version": "temurin-21.0.5", "requested_version": "temurin-21", "installed": true, "source": {"path": ` + strconv.Quote(tg.File) + `}}
		],
		"go": [{"version": "1.26.0", "requested_version": "latest", "installed": false, "source": {"path": ` + strconv.Quote(other) + `}}],
		"jq": [{"version": "1.7.1", "installed": true}]
	}`}}
	p := New(r)
	actions, err := p.Plan(context.Background(), tg)
	if err != nil || len(actions) != 1 || actions[0].Resource != "java@temurin-25" {
		t.Fatalf("plan %+v %v", actions, err)
	}
	_ = actions[0].Do(context.Background())
	if want := "mise install -C " + filepath.Dir(tg.File) + " java@temurin-25"; r.Ran[0] != want {
		t.Fatalf("ran %v", r.Ran)
	}
	live, err := p.Measure(context.Background(), tg)
	if err != nil || live.InPlace != 2 || live.Declared != 3 {
		t.Fatalf("live %+v %v", live, err)
	}
	items, err := p.Items(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, i := range items {
		got = append(got, i.Name+" "+i.Version+" "+i.State+" ("+i.Desc+")")
	}
	want := "java temurin-21.0.5 in place (requested temurin-21)\njava temurin-25.0.1 missing (requested temurin-25)\nnode 22.11.0 in place (requested lts)\n" +
		"jq 1.7.1 not declared (installed, no config asks for it)"
	if strings.Join(got, "\n") != want {
		t.Fatalf("items\n%s", strings.Join(got, "\n"))
	}
}

func TestUntrustedConfigIsManual(t *testing.T) {
	tg, ls := setup(t)
	r := &sh.Fake{Programs: []string{"mise"}, Err: map[string]error{ls: errors.New("mise ERROR Config files in ~/x are not trusted.")}}
	actions, err := New(r).Plan(context.Background(), tg)
	if err != nil || len(actions) != 1 || actions[0].Op != plan.OpManual || !strings.Contains(actions[0].Detail, "mise trust") {
		t.Fatalf("plan %+v %v", actions, err)
	}
}

func TestMissingMiseIsManual(t *testing.T) {
	tg, _ := setup(t)
	actions, err := New(&sh.Fake{}).Plan(context.Background(), tg)
	if err != nil || len(actions) != 1 || actions[0].Resource != "mise" {
		t.Fatalf("plan %+v %v", actions, err)
	}
}

func TestOutdatedExtraUpgradeAndCapture(t *testing.T) {
	tg, ls := setup(t)
	dir := filepath.Dir(tg.File)
	r := &sh.Fake{Programs: []string{"mise"}, Out: map[string]string{
		ls: `{
		"node": [
			{"version": "24.1.0", "requested_version": "lts", "installed": true, "source": {"path": ` + strconv.Quote(tg.File) + `}},
			{"version": "22.22.2", "installed": true}
		],
		"jq": [{"version": "1.7.1", "requested_version": "latest", "installed": true, "source": {"path": "/home/me/.config/mise/config.toml"}}]
		}`,
		"mise outdated --json -C " + dir: `{"node": {"name": "node", "requested": "lts", "current": "24.1.0", "latest": "24.2.0"}}`,
	}}
	p := New(r)
	items, err := p.Items(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, i := range items {
		got = append(got, i.Name+" "+i.State+" "+i.Version+" "+i.Latest+" ("+i.Desc+")")
	}
	want := "node outdated 24.1.0 24.2.0 (requested lts)\n" +
		"jq not declared 1.7.1  (declared in /home/me/.config/mise/config.toml)\n" +
		"node not declared 22.22.2  (installed, no config asks for it)"
	if strings.Join(got, "\n") != want {
		t.Fatalf("items\n%s", strings.Join(got, "\n"))
	}
	tg.Upgrade = true
	actions, err := p.Plan(context.Background(), tg)
	if err != nil || len(actions) != 1 || actions[0].Op != plan.OpUpdate || actions[0].Detail != "upgrade with mise, 24.1.0 to 24.2.0" {
		t.Fatalf("plan %+v %v", actions, err)
	}
	_ = actions[0].Do(context.Background())
	if r.Ran[0] != "mise upgrade -C "+dir+" node@lts" {
		t.Fatalf("ran %v", r.Ran)
	}
	out, err := p.Capture(context.Background(), tg)
	if err != nil || string(out) != "# Captured by zc-care from what mise has installed.\n[tools]\njq = \"latest\"\nnode = [\"lts\", \"22.22.2\"]\n" {
		t.Fatalf("capture %v\n%s", err, out)
	}
}

func TestAddPutsTheToolInTheToolsTable(t *testing.T) {
	file := filepath.Join(t.TempDir(), "mise.toml")
	if err := os.WriteFile(file, []byte("[tools]\nnode = \"lts\" # web\n\n[settings]\nx = 1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	tg := config.Target{Name: "rt", Provider: "tools", File: file}
	p := New(&sh.Fake{})
	if err := p.Add(tg, provider.Entry{Name: "node@22"}); err == nil {
		t.Fatal("duplicate added")
	}
	if err := p.Add(tg, provider.Entry{Name: "npm:prettier", Why: "formatter"}); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(file)
	if want := "[tools]\nnode = \"lts\" # web\n\"npm:prettier\" = \"latest\" # formatter\n\n[settings]\nx = 1\n"; string(b) != want {
		t.Fatalf("mise.toml:\n%s", b)
	}
	if n := declaredTools(b); n["npm:prettier"].Why != "formatter" || n["node"].Why != "web" || len(n) != 2 {
		t.Fatalf("notes %+v", n)
	}
}
