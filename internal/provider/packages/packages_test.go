package packages

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

const brewfile = `# taps come first in the plan even when listed last
brew "git"
brew "FelixKratz/formulae/sketchybar"
cask "ghostty"
mas "Bitwarden", id: 1352778147
mas "uBlock Origin Lite", id: 6745342698
vscode "golang.go"
tap "felixkratz/formulae"
tap "hashicorp/tap"
`

func writeManifest(t *testing.T, name, body string) config.Target {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return config.Target{Name: "pkgs", Provider: "packages", File: path}
}

func brewMachine() *sh.Fake {
	return &sh.Fake{
		Programs: []string{"brew", "mas"},
		Out: map[string]string{
			"brew list --formula -1":          "git\nsketchybar\n",
			"brew list --cask -1":             "",
			"brew list --cask -1 --full-name": "",
			"brew tap":                        "FelixKratz/formulae\n",
			"mas list":                        "1352778147  Bitwarden  (2026.9.1)\n",
		},
	}
}

func resources(actions []plan.Action) []string {
	var out []string
	for _, a := range actions {
		out = append(out, string(a.Op)+" "+a.Resource)
	}
	return out
}

func TestBrewPlanInstallsWhatIsMissing(t *testing.T) {
	r := brewMachine()
	tg := writeManifest(t, "Brewfile", brewfile)
	actions, err := New(r).Plan(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(resources(actions), ", ")
	want := "MANUAL unsupported:vscode:golang.go, CREATE tap:hashicorp/tap, CREATE cask:ghostty, CREATE mas:uBlock Origin Lite"
	if got != want {
		t.Fatalf("plan\n got %s\nwant %s", got, want)
	}
	for _, a := range actions {
		if a.Do != nil {
			if err := a.Do(context.Background()); err != nil {
				t.Fatal(err)
			}
		}
	}
	ran := strings.Join(r.Ran, "\n")
	if ran != "brew tap -- hashicorp/tap\nbrew trust -- hashicorp/tap\nbrew install --cask --adopt -- ghostty\nsudo mas install 6745342698" {
		t.Fatalf("ran\n%s", ran)
	}
}

func TestBrewMeasure(t *testing.T) {
	live, err := New(brewMachine()).Measure(context.Background(), writeManifest(t, "Brewfile", brewfile))
	if err != nil {
		t.Fatal(err)
	}
	if live.InPlace != 4 || live.Declared != 7 || live.Summary != "4 of 7 packages installed (brew), 1 manual" {
		t.Fatalf("live %+v", live)
	}
}

func TestSkippedPackagesAreNeitherPlannedNorCounted(t *testing.T) {
	r := brewMachine()
	tg := writeManifest(t, "Brewfile", brewfile)
	// git is installed, so skipping it changes nothing.
	tg.Skip = []string{"cask:ghostty", "brew:git"}
	p := New(r)
	actions, err := p.Plan(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(resources(actions), ", "); strings.Contains(got, "ghostty") {
		t.Fatalf("plan installs a skipped package: %s", got)
	}
	live, err := p.Measure(context.Background(), tg)
	if err != nil || live.InPlace != 4 || live.Declared != 6 {
		t.Fatalf("live %+v, %v", live, err)
	}
	items, err := p.Items(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	states := map[string]string{}
	for _, i := range items {
		states[i.Kind+":"+i.Name] = i.State
	}
	if states["cask:ghostty"] != provider.Skipped || states["brew:git"] != provider.InPlace {
		t.Fatalf("states %v", states)
	}
}

func TestMasMissingMakesAppStoreAppsManual(t *testing.T) {
	r := brewMachine()
	r.Programs = []string{"brew"}
	actions, err := New(r).Plan(context.Background(), writeManifest(t, "Brewfile", `mas "Bitwarden", id: 1352778147`))
	if err != nil || len(actions) != 1 || actions[0].Op != plan.OpManual || !strings.Contains(actions[0].Detail, "brew install mas") {
		t.Fatalf("plan %+v %v", actions, err)
	}
}

func TestMissingManagerIsOneManualStep(t *testing.T) {
	actions, err := New(&sh.Fake{}).Plan(context.Background(), writeManifest(t, "Brewfile", brewfile))
	if err != nil || len(actions) != 1 || actions[0].Op != plan.OpManual || actions[0].Resource != "brew" {
		t.Fatalf("plan %+v %v", actions, err)
	}
	if _, err := New(&sh.Fake{}).Measure(context.Background(), writeManifest(t, "Brewfile", brewfile)); err == nil {
		t.Fatal("measured without brew")
	}
}

func TestBadBrewfile(t *testing.T) {
	for _, body := range []string{"brew git\n", `mas "Bitwarden"`} {
		if _, err := New(brewMachine()).Plan(context.Background(), writeManifest(t, "Brewfile", body)); err == nil {
			t.Errorf("accepted %q", body)
		}
	}
}

func TestItemsCarryStateVersionAndDescription(t *testing.T) {
	r := brewMachine()
	r.Out["brew info --json=v2 --installed"] = `{
		"formulae": [{"name": "git", "full_name": "git", "desc": "Distributed revision control system",
			"homepage": "https://git-scm.com", "installed": [{"version": "2.56.0"}]},
			{"name": "sketchybar", "full_name": "felixkratz/formulae/sketchybar", "desc": "Custom macOS statusbar",
			"installed": [{"version": "2.22.1"}]}],
		"casks": []}`
	items, err := New(r).Items(context.Background(), writeManifest(t, "Brewfile", brewfile))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, i := range items {
		got = append(got, strings.Join([]string{i.Kind, i.Name, i.State, i.Version, i.App, i.Desc}, "|"))
	}
	want := []string{
		"tap|felixkratz/formulae|in place|||",
		"tap|hashicorp/tap|missing|||",
		"brew|git|in place|2.56.0||Distributed revision control system",
		"brew|FelixKratz/formulae/sketchybar|in place|2.22.1||Custom macOS statusbar",
		"cask|ghostty|missing|||",
		"mas|Bitwarden|in place|2026.9.1|Bitwarden|",
		"mas|uBlock Origin Lite|missing|||",
		"vscode|golang.go|manual|||zc-care does not install this kind of entry",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("items\n%s", strings.Join(got, "\n"))
	}
}

func TestItemsWithoutDetailsStillList(t *testing.T) {
	r := brewMachine() // no brew info answer: details fail, items do not
	items, err := New(r).Items(context.Background(), writeManifest(t, "Brewfile", `brew "git"`))
	if err != nil || len(items) != 1 || items[0].State != "in place" || items[0].Version != "" {
		t.Fatalf("items %+v %v", items, err)
	}
}

const outdatedJSON = `{"formulae": [
	{"name": "git", "installed_versions": ["2.56.0"], "current_version": "2.57.0", "pinned": false},
	{"name": "tmux", "installed_versions": ["3.7"], "current_version": "3.8", "pinned": true}],
	"casks": []}`

func TestItemsShowUpdatesAndUndeclared(t *testing.T) {
	r := brewMachine()
	r.Out["brew outdated --json=v2"] = outdatedJSON
	r.Out["brew leaves --installed-on-request"] = "git\nfelixkratz/formulae/sketchybar\njq\n"
	r.Out["brew list --cask -1 --full-name"] = "raycast\n"
	r.Out["mas list"] = "1352778147  Bitwarden  (2026.9.1)\n640199958  Developer  (11.1)\n"
	r.Out["mas outdated"] = "1352778147 Bitwarden (2026.9.1 -> 2026.10.0)\n"
	items, err := New(r).Items(context.Background(), writeManifest(t, "Brewfile", brewfile))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, i := range items {
		if i.State == "outdated" || i.State == "not declared" {
			got = append(got, i.Kind+"|"+i.Name+"|"+i.State+"|"+i.Version+"|"+i.Latest)
		}
	}
	want := []string{
		"brew|git|outdated|2.56.0|2.57.0",
		"mas|Bitwarden|outdated|2026.9.1|2026.10.0",
		"brew|jq|not declared||",
		"cask|raycast|not declared||",
		"mas|Developer|not declared||",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("items\n%s", strings.Join(got, "\n"))
	}
}

func TestUpgradeIsOptIn(t *testing.T) {
	r := brewMachine()
	r.Out["brew outdated --json=v2"] = outdatedJSON
	r.Out["mas outdated"] = ""
	tg := writeManifest(t, "Brewfile", `brew "git"`+"\n"+`brew "tmux"`)
	r.Out["brew list --formula -1"] += "tmux\n"
	if actions, _ := New(r).Plan(context.Background(), tg); len(actions) != 0 {
		t.Fatalf("plan without upgrade %v", resources(actions))
	}
	tg.Upgrade = true
	actions, err := New(r).Plan(context.Background(), tg)
	// tmux is pinned, so only git upgrades.
	if err != nil || strings.Join(resources(actions), ",") != "UPDATE brew:git" || actions[0].Detail != "upgrade with brew, 2.56.0 to 2.57.0" {
		t.Fatalf("plan %v %v", actions, err)
	}
	_ = actions[0].Do(context.Background())
	if r.Ran[0] != "brew upgrade -- git" {
		t.Fatalf("ran %v", r.Ran)
	}
}

func TestCaptureWritesABrewfile(t *testing.T) {
	r := brewMachine()
	r.Out["brew tap"] = "homebrew/core\nfelixkratz/formulae\n"
	r.Out["brew leaves --installed-on-request"] = "git\n"
	r.Out["brew list --cask -1 --full-name"] = "ghostty\n"
	got, err := New(r).Capture(context.Background(), writeManifest(t, "Brewfile", ""))
	want := "# Captured by zc-care from what this machine has installed.\n" +
		"tap \"felixkratz/formulae\"\nbrew \"git\"\ncask \"ghostty\"\nmas \"Bitwarden\", id: 1352778147\n"
	if err != nil || string(got) != want {
		t.Fatalf("capture %v\n%s", err, got)
	}
	// A captured Brewfile reads back.
	if _, _, err := parseBrewfile(got); err != nil {
		t.Fatal(err)
	}
}

func TestAddRefusesALineBreakInTheSection(t *testing.T) {
	tg := writeManifest(t, "Brewfile", "# Git\nbrew \"git\"\n")
	err := New(brewMachine()).Add(tg, provider.Entry{Name: "lazygit", Section: "Git\ncask \"evil\""})
	if err == nil {
		t.Fatal("section with a line break accepted")
	}
	if b, _ := os.ReadFile(tg.File); string(b) != "# Git\nbrew \"git\"\n" {
		t.Fatalf("Brewfile changed:\n%s", b)
	}
}

func TestAddDeclaresUnderASectionWithItsTap(t *testing.T) {
	tg := writeManifest(t, "Brewfile", "tap \"a/b\"\n\n# Git\nbrew \"git\" # version control\n")
	p := New(brewMachine())
	if err := p.Add(tg, provider.Entry{Name: "lazygit"}); err == nil || !strings.Contains(err.Error(), "choose a section: Git") {
		t.Fatalf("no section: %v", err)
	}
	if err := p.Add(tg, provider.Entry{Kind: "brew", Name: "git", Section: "Git"}); err == nil {
		t.Fatal("duplicate added")
	}
	if err := p.Add(tg, provider.Entry{Name: "cirruslabs/cli/tart", Section: "git", Why: "macOS VMs"}); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(tg.File)
	if want := "tap \"a/b\"\ntap \"cirruslabs/cli\" # tart\n\n# Git\nbrew \"git\" # version control\nbrew \"cirruslabs/cli/tart\" # macOS VMs\n"; string(b) != want {
		t.Fatalf("Brewfile:\n%s", b)
	}
	items, err := p.Items(context.Background(), tg)
	if err != nil || items[2].Why != "version control" || items[2].Section != "Git" {
		t.Fatalf("items %+v %v", items, err)
	}
}

func TestPlanRemoveIsADeleteThatUninstallsAndDropsTheLine(t *testing.T) {
	tg := writeManifest(t, "Brewfile", "# Git\nbrew \"git\" # version control\nbrew \"htop\" # processes\nmas \"Pages\", id: 361309726 # documents\n")
	r := &sh.Fake{}
	p := New(r)
	var actions []plan.Action
	for _, c := range [][2]string{{"brew", "HTOP"}, {"mas", "Pages"}, {"mas", "409201541"}} {
		a, err := p.PlanRemove(tg, c[0], c[1])
		if err != nil {
			t.Fatal(err)
		}
		actions = append(actions, a)
	}
	if len(r.Ran) != 0 {
		t.Fatalf("planning ran %q", r.Ran)
	}
	if got := strings.Join(resources(actions), ","); got != "DELETE brew:htop,DELETE mas:Pages,DELETE mas:409201541" {
		t.Fatalf("plan %s", got)
	}
	for _, a := range actions {
		if err := a.Do(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if want := "brew uninstall -- htop\nsudo mas uninstall 361309726\nsudo mas uninstall 409201541"; strings.Join(r.Ran, "\n") != want {
		t.Fatalf("ran %q", r.Ran)
	}
	b, _ := os.ReadFile(tg.File)
	if want := "# Git\nbrew \"git\" # version control\n"; string(b) != want {
		t.Fatalf("Brewfile:\n%s", b)
	}
}

func TestPlanRemoveRefusesWhatBrewWouldReadAsAFlag(t *testing.T) {
	tg := writeManifest(t, "Brewfile", "brew \"git\"\n")
	p := New(&sh.Fake{})
	for _, c := range [][2]string{
		{"brew", "--force"}, {"cask", "--zap"}, {"tap", "-v"}, {"", "--force"},
		{"mas", "Pages"}, {"mas", "-1"}, {"vscode", "golang.go"},
	} {
		if _, err := p.PlanRemove(tg, c[0], c[1]); err == nil {
			t.Fatalf("%s:%s planned", c[0], c[1])
		}
	}
}

func TestInstallPutsManifestNamesAfterTheOptionTerminator(t *testing.T) {
	r := &sh.Fake{}
	for _, i := range []item{{Kind: "brew", Name: "--force"}, {Kind: "cask", Name: "--zap"}} {
		if err := brew.install(r, i)(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if want := "brew install -- --force\nbrew install --cask --adopt -- --zap"; strings.Join(r.Ran, "\n") != want {
		t.Fatalf("ran %q", r.Ran)
	}
}
