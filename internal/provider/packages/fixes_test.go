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
	if want := []string{"tap:a/b", "brew:git", "brew:x", "mas:Big App", "cask:ghostty"}; !slices.Equal(got, want) {
		t.Errorf("items %q, want %q", got, want)
	}
	if items[3].ID != "42" {
		t.Errorf("mas id %q", items[3].ID)
	}
	if want := []string{`cask_args appdir: "/Applications"`, "if OS.mac?", "end"}; !slices.Equal(unsupported, want) {
		t.Errorf("unsupported %q, want %q", unsupported, want)
	}
}
