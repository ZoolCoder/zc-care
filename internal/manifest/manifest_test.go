package manifest

import (
	"reflect"
	"strings"
	"testing"
)

const brewfile = `tap "a/b"

# Terminal
cask "ghostty" # fast native terminal
brew "tmux"

# Git [Developer, ops]
# More about git tools.
brew "gh" # GitHub from the terminal
`

func brewKey(l string) (string, bool) {
	kind, name, ok := strings.Cut(l, " ")
	return kind + ":" + strings.Trim(name, `"`), ok
}

func TestNotesReadSectionsAndWhy(t *testing.T) {
	n := Notes([]byte(brewfile), brewKey)
	if got := n["cask:ghostty"]; !reflect.DeepEqual(got, Note{Section: "Terminal", Why: "fast native terminal"}) {
		t.Fatalf("ghostty %+v", got)
	}
	want := Note{Section: "Git", Profiles: []string{"developer", "ops"}, Why: "GitHub from the terminal"}
	if got := n["brew:gh"]; !reflect.DeepEqual(got, want) {
		t.Fatalf("gh %+v", got)
	}
	if got := n["tap:a/b"]; !reflect.DeepEqual(got, Note{}) {
		t.Fatalf("tap %+v", got)
	}
	if got := strings.Join(Sections([]byte(brewfile)), ","); got != "Terminal,Git" {
		t.Fatalf("sections %s", got)
	}
}

func TestSplitIgnoresHashInQuotes(t *testing.T) {
	if e, w := split(`brew "c#" # sharp`); e != `brew "c#"` || w != "sharp" {
		t.Fatalf("%q %q", e, w)
	}
}

func TestInsert(t *testing.T) {
	for _, c := range []struct{ section, want string }{
		{"terminal", "brew \"tmux\"\nX\n\n# Git"},
		{"", "tap \"a/b\"\nX\n\n# Terminal"},
		{"Cloud", "GitHub from the terminal\n\n# Cloud\nX\n"},
	} {
		if got := string(Insert([]byte(brewfile), c.section, "X")); !strings.Contains(got, c.want) {
			t.Fatalf("section %q:\n%s", c.section, got)
		}
	}
	if got := string(Insert([]byte("# Only\nbrew \"a\"\n"), "", "X")); !strings.HasPrefix(got, "X\n\n# Only") {
		t.Fatalf("empty top block:\n%s", got)
	}
}

func TestLineRefusesNewlines(t *testing.T) {
	if _, err := Line("brew \"a\"", "one\ntwo"); err == nil {
		t.Fatal("multi-line why accepted")
	}
	if got, _ := Line("brew \"a\"", " fast "); got != `brew "a" # fast` {
		t.Fatal(got)
	}
}

func TestTopCommentIsAboutTheFile(t *testing.T) {
	data := []byte("# About this file.\n# More.\n\ntap \"a/b\"\n\n# Git\nbrew \"gh\"\n\n# Work\n# Empty for now.\n")
	if got := strings.Join(Sections(data), ","); got != "Git,Work" {
		t.Fatalf("sections %s", got)
	}
	if got := string(Insert(data, "", "X")); !strings.Contains(got, "tap \"a/b\"\nX\n") {
		t.Fatalf("top block:\n%s", got)
	}
	if got := string(Insert(data, "work", "X")); !strings.HasSuffix(got, "# Empty for now.\nX\n") {
		t.Fatalf("empty last section:\n%s", got)
	}
}
