package manifest

import (
	"os"
	"path/filepath"
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

func insert(t *testing.T, data, section string) string {
	t.Helper()
	got, err := Insert([]byte(data), section, "X")
	if err != nil {
		t.Fatal(err)
	}
	return string(got)
}

func TestInsertRefusesALineBreakInTheSection(t *testing.T) {
	for _, section := range []string{"Terminal\nbrew \"evil\"", "Terminal\rbrew \"evil\""} {
		if _, err := Insert([]byte(brewfile), section, "X"); err == nil {
			t.Fatalf("section %q accepted", section)
		}
	}
}

func TestWriteFileReplacesInOneRenameAndKeepsASymlink(t *testing.T) {
	dir := t.TempDir()
	real, link := filepath.Join(dir, "real"), filepath.Join(dir, "link")
	if err := os.WriteFile(real, []byte("old\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	if err := WriteFile(link, []byte("new\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(real)
	info, _ := os.Lstat(link)
	if string(b) != "new\n" || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("real %q, link mode %v", b, info.Mode())
	}
	if st, _ := os.Stat(real); st.Mode().Perm() != 0o640 {
		t.Fatalf("mode %v", st.Mode())
	}
	if left, _ := filepath.Glob(filepath.Join(dir, ".*")); len(left) != 0 {
		t.Fatalf("temp files left: %v", left)
	}
}

func TestInsert(t *testing.T) {
	for _, c := range []struct{ section, want string }{
		{"terminal", "brew \"tmux\"\nX\n\n# Git"},
		{"", "tap \"a/b\"\nX\n\n# Terminal"},
		{"Cloud", "GitHub from the terminal\n\n# Cloud\nX\n"},
	} {
		if got := insert(t, brewfile, c.section); !strings.Contains(got, c.want) {
			t.Fatalf("section %q:\n%s", c.section, got)
		}
	}
	if got := insert(t, "# Only\nbrew \"a\"\n", ""); !strings.HasPrefix(got, "X\n\n# Only") {
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
	if got := insert(t, string(data), ""); !strings.Contains(got, "tap \"a/b\"\nX\n") {
		t.Fatalf("top block:\n%s", got)
	}
	if got := insert(t, string(data), "work"); !strings.HasSuffix(got, "# Empty for now.\nX\n") {
		t.Fatalf("empty last section:\n%s", got)
	}
}
