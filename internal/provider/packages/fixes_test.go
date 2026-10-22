package packages

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

const ghosttyInfo = `{"casks":[{"token":"ghostty","artifacts":[{"app":["Ghostty.app"]},{"zap":[{"trash":["~/x"]}]},{"binary":["a"]}]}]}`

func TestAdoptedCaskCannotBeUndone(t *testing.T) {
	apps := t.TempDir()
	old := applicationsDirs
	applicationsDirs = []string{apps}
	t.Cleanup(func() { applicationsDirs = old })

	r := brewMachine()
	r.Out["brew info --cask --json=v2 -- ghostty"] = ghosttyInfo
	cask := item{Kind: "cask", Name: "ghostty"}

	u, err := beforeInstall(r, cask)(context.Background())
	if err != nil || u.Verb != "uninstall" || u.Reason != "" {
		t.Fatalf("fresh install: %+v, %v", u, err)
	}

	if err := os.Mkdir(filepath.Join(apps, "Ghostty.app"), 0o755); err != nil {
		t.Fatal(err)
	}
	u, err = beforeInstall(r, cask)(context.Background())
	if err != nil || u.Reason != "adopted an existing app" {
		t.Fatalf("adopted install: %+v, %v", u, err)
	}

	// A formula never adopts anything and asks brew nothing.
	u, err = beforeInstall(r, item{Kind: "brew", Name: "git"})(context.Background())
	if err != nil || u.Verb != "uninstall" {
		t.Fatalf("formula: %+v, %v", u, err)
	}
}

func TestBrewfileLinesItCannotReadAreManualNotFatal(t *testing.T) {
	data := `cask_args appdir: "/Applications"
brew 'git'
brew "x",
  args: ["with-foo"]
mas "Big App",
  id: 42
if OS.mac?
  cask "ghostty"
end
tap 'a/b'
`
	items, unsupported, err := parseBrewfile([]byte(data))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, i := range items {
		got = append(got, i.resource())
	}
	if want := []string{"tap:a/b", "brew:git", "brew:x", "mas:Big App"}; !slices.Equal(got, want) {
		t.Errorf("items %q, want %q", got, want)
	}
	if items[3].ID != "42" {
		t.Errorf("mas id %q", items[3].ID)
	}
	if want := []string{`cask_args appdir: "/Applications"`, "if OS.mac?", `cask "ghostty" (inside a conditional block, which is not evaluated)`, "end"}; !slices.Equal(unsupported, want) {
		t.Errorf("unsupported %q, want %q", unsupported, want)
	}
}

func TestBrewfileConditionalBlocksAreNeverInstalled(t *testing.T) {
	data := `brew "a"
unless OS.mac?
  brew "b"
  if system "true"
    brew "c"
  end
  brew "d"
end
brew "e"
`
	items, unsupported, err := parseBrewfile([]byte(data))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, i := range items {
		got = append(got, i.resource())
	}
	if want := []string{"brew:a", "brew:e"}; !slices.Equal(got, want) {
		t.Errorf("items %q, want %q", got, want)
	}
	if len(unsupported) != 7 {
		t.Errorf("unsupported %q", unsupported)
	}
}

func TestHomeApplicationsCountsAsAnAdoptionFolder(t *testing.T) {
	home, _ := os.UserHomeDir()
	if !slices.Contains(applicationsDirs, filepath.Join(home, "Applications")) || !slices.Contains(applicationsDirs, "/Applications") {
		t.Fatalf("dirs %q", applicationsDirs)
	}
}

func TestBrewfileCommentsDoNotBreakContinuations(t *testing.T) {
	for name, data := range map[string]string{
		"trailing comment": "mas \"X\", # note\n  id: 123\n",
		"comment inside":   "mas \"X\",\n  # why\n  id: 123\n",
		"hash in quotes":   "mas \"X#1\", id: 123 # note\n",
	} {
		items, unsupported, err := parseBrewfile([]byte(data))
		if err != nil || len(unsupported) != 0 || len(items) != 1 || items[0].ID != "123" {
			t.Errorf("%s: items %+v unsupported %q err %v", name, items, unsupported, err)
		}
	}
}
