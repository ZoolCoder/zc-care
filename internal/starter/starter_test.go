package starter

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/manifest"
)

func TestTheStarterConfigIsValid(t *testing.T) {
	data, err := files.ReadFile("zc-care.yaml")
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Parse(data)
	if err != nil {
		t.Fatal(err)
	}
	known := append(Names(), Roles...)
	for _, tg := range cfg.Targets {
		for _, p := range tg.Profiles {
			if !slices.Contains(known, p) {
				t.Errorf("target %s: profile %q is not a starter profile", tg.Name, p)
			}
		}
	}
}

// Every tagged section must be for a profile init offers, or no one could
// ever pick it.
func TestEveryBrewfileSectionIsForAKnownProfile(t *testing.T) {
	data, _ := files.ReadFile("Brewfile")
	notes := manifest.Notes(data, resource)
	if len(notes) < 20 {
		t.Fatalf("only %d entries read", len(notes))
	}
	for r, n := range notes {
		if n.Section == "" || n.Why == "" {
			t.Errorf("%s: a starter entry needs a section and a why: %+v", r, n)
		}
		for _, p := range n.Profiles {
			if !slices.Contains(Names(), p) {
				t.Errorf("%s: profile %q is not a starter profile", r, p)
			}
		}
	}
}

func TestWriteSkipsOtherProfilesAndKeepsWhatTheMacHas(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "zc-care")
	captured := "# Captured by zc-care from what this machine has installed.\n" +
		"tap \"felixkratz/formulae\"\nbrew \"git\"\ncask \"zed\"\nmas \"Bitwarden\", id: 1352778147\n"
	res, err := Write(Options{Dir: dir, Profiles: []string{"developer"}, Captured: []byte(captured)})
	if err != nil {
		t.Fatal(err)
	}
	if res.Config != filepath.Join(dir, "zc-care.yaml") || len(res.Files) != 3 || res.Kept != 3 {
		t.Fatalf("result %+v", res)
	}
	for _, want := range []string{"cask:firefox", "cask:figma"} {
		if !slices.Contains(res.Skip, want) {
			t.Errorf("skip lacks %s: %v", want, res.Skip)
		}
	}
	for _, not := range []string{"cask:ghostty", "cask:rectangle", "brew:git", "cask:zed"} {
		if slices.Contains(res.Skip, not) {
			t.Errorf("skip has %s", not)
		}
	}
	b, _ := os.ReadFile(filepath.Join(dir, "Brewfile"))
	if !strings.HasSuffix(string(b), "\n\n# From this Mac\ntap \"felixkratz/formulae\" # on this Mac before zc-care init\n"+
		"cask \"zed\" # on this Mac before zc-care init\nmas \"Bitwarden\", id: 1352778147 # on this Mac before zc-care init\n") {
		t.Fatalf("Brewfile:\n%s", b)
	}
	if strings.Count(string(b), `brew "git"`) != 1 {
		t.Fatal("git twice")
	}
	if _, err := Write(Options{Dir: dir, Profiles: []string{"developer"}}); err == nil || !strings.Contains(err.Error(), "exists") {
		t.Fatalf("second write: %v", err)
	}
	if _, err := Write(Options{Dir: dir, Profiles: []string{"everyday"}, Force: true}); err != nil {
		t.Fatal(err)
	}
}

func TestWriteNeedsAKnownProfile(t *testing.T) {
	for _, profiles := range [][]string{nil, {"gamer"}} {
		if _, err := Write(Options{Dir: t.TempDir(), Profiles: profiles}); err == nil {
			t.Errorf("%v accepted", profiles)
		}
	}
}
