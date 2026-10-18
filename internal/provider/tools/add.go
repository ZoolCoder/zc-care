package tools

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/manifest"
	"github.com/zoolcoder/zc-care/internal/provider"
)

var (
	toolName = regexp.MustCompile(`^[a-z0-9][a-z0-9:._/@-]*$`)
	bareKey  = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
	toolVer  = regexp.MustCompile(`^[A-Za-z0-9._+-]+$`)
)

// Add declares e, written tool@version, in the [tools] table of t's file,
// with e.Why at the end of its line. A bare tool name asks for latest.
func (p Provider) Add(t config.Target, e provider.Entry) error {
	if e.Kind != "" && e.Kind != "runtime" {
		return fmt.Errorf("a mise config declares runtimes, not %q", e.Kind)
	}
	name, ver, ok := strings.Cut(e.Name, "@")
	if !ok {
		ver = "latest"
	}
	if !toolName.MatchString(name) || !toolVer.MatchString(ver) {
		return fmt.Errorf("%q is not tool@version", e.Name)
	}
	key := name
	if !bareKey.MatchString(key) {
		key = strconv.Quote(key)
	}
	line, err := manifest.Line(key+" = "+strconv.Quote(ver), e.Why)
	if err != nil {
		return err
	}
	info, err := os.Stat(t.File)
	if err != nil {
		return err
	}
	data, err := os.ReadFile(t.File)
	if err != nil {
		return err
	}
	if _, ok := declaredTools(data)[name]; ok {
		return fmt.Errorf("%s already declares %s", t.File, name)
	}
	return os.WriteFile(t.File, insertTool(data, line), info.Mode().Perm())
}

// declaredTools reads the [tools] table's comments, by tool name.
func declaredTools(data []byte) map[string]manifest.Note {
	inTools := false
	return manifest.Notes(data, func(l string) (string, bool) {
		if strings.HasPrefix(l, "[") {
			inTools = l == "[tools]"
			return "", false
		}
		k, _, ok := strings.Cut(l, "=")
		if !inTools || !ok {
			return "", false
		}
		k = strings.TrimSpace(k)
		if u, err := strconv.Unquote(k); err == nil {
			k = u
		}
		return k, true
	})
}

// insertTool puts line after the last line of the [tools] table, or starts
// the table at the end of the file.
func insertTool(data []byte, line string) []byte {
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	at := -1
	for n, l := range lines {
		t := strings.TrimSpace(l)
		switch {
		case t == "[tools]":
			at = n
		case strings.HasPrefix(t, "[") && at >= 0:
			return join(lines, at, line)
		case t != "" && at >= 0:
			at = n
		}
	}
	if at >= 0 {
		return join(lines, at, line)
	}
	return []byte(strings.TrimRight(string(data), "\n") + "\n\n[tools]\n" + line + "\n")
}

func join(lines []string, after int, line string) []byte {
	out := append(append(lines[:after+1:after+1], line), lines[after+1:]...)
	return []byte(strings.Join(out, "\n") + "\n")
}
