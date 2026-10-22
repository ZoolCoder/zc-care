// Package manifest reads and edits the comments people write in line-based
// manifests, such as a Brewfile, a package list or a mise.toml. A comment
// line that opens a block, after a blank line or at the top of the file, is
// that block's section heading; a comment block at the top that a blank line
// ends is about the whole file instead. A comment at the end of an entry's
// line says why the entry is there. A heading may end in the profiles its
// entries are for, such as "# Containers [developer]"; a section without
// any is for everyone.
package manifest

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// Note is what the comments say about one entry.
type Note struct {
	Section  string   `json:"section,omitempty"`
	Profiles []string `json:"profiles,omitempty"`
	Why      string   `json:"why,omitempty"`
}

// Key reads an entry line, without its trailing comment, and returns the
// entry's key, or false for a line that is not an entry.
type Key func(line string) (string, bool)

// Notes maps each entry's key to its section and why.
func Notes(data []byte, key Key) map[string]Note {
	notes := map[string]Note{}
	for _, l := range scan(data) {
		if k, ok := key(l.entry); ok {
			notes[k] = Note{Section: l.section, Profiles: l.profiles, Why: l.why}
		}
	}
	return notes
}

// Sections lists the section headings in file order.
func Sections(data []byte) []string {
	var out []string
	for _, l := range scan(data) {
		if l.heading && !slices.Contains(out, l.section) {
			out = append(out, l.section)
		}
	}
	return out
}

// Insert adds entry as the last line of section's block, matched without
// regard to case. The empty section is the block above the first heading.
// A section the file does not have is appended as a new block, which a
// section with a line break cannot be.
func Insert(data []byte, section, entry string) ([]byte, error) {
	if strings.ContainsAny(section, "\r\n") {
		return nil, fmt.Errorf("the section must be one line")
	}
	lines := scan(data)
	at := -1
	for n, l := range lines {
		if strings.EqualFold(l.section, section) && l.text != "" {
			at = n
		}
	}
	raw := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	switch {
	case at >= 0:
		raw = slices.Insert(raw, at+1, entry)
	case section == "":
		raw = slices.Insert(raw, 0, entry, "")
	default:
		raw = append(raw, "", "# "+section, entry)
	}
	return []byte(strings.Join(raw, "\n") + "\n"), nil
}

// Drop removes the entry whose key is want, matched without regard to case,
// and reports whether there was one. An entry whose line ends in a comma or
// leaves a [ open goes on in the next line, as in a Brewfile, and those lines
// go with it.
func Drop(data []byte, key Key, want string) ([]byte, bool) {
	raw := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	lines := scan(data)
	for n, l := range lines {
		if k, ok := key(l.entry); ok && strings.EqualFold(k, want) {
			end, open := n, openBrackets(l.entry)
			for end+1 < len(lines) && (open > 0 || strings.HasSuffix(lines[end].entry, ",")) {
				end++
				open += openBrackets(lines[end].entry)
			}
			return []byte(strings.Join(slices.Delete(raw, n, end+1), "\n") + "\n"), true
		}
	}
	return data, false
}

// openBrackets counts the [ a line opens beyond the ] it closes, outside
// quotes.
func openBrackets(entry string) int {
	depth, quote := 0, rune(0)
	for _, r := range entry {
		switch {
		case quote != 0:
			if r == quote {
				quote = 0
			}
		case r == '"' || r == '\'':
			quote = r
		case r == '[':
			depth++
		case r == ']':
			depth--
		}
	}
	return depth
}

// Line is an entry and its why, as one manifest line.
func Line(entry, why string) (string, error) {
	if strings.ContainsAny(why, "\r\n") {
		return "", fmt.Errorf("the why must be one line")
	}
	if why = strings.TrimSpace(why); why == "" {
		return entry, nil
	}
	return entry + " # " + why, nil
}

// WriteFile replaces path with data in one rename, so a crash or a reader at
// the same moment sees the old file or the new one, never half. It writes
// through a symlink instead of replacing it.
func WriteFile(path string, data []byte, perm os.FileMode) error {
	if real, err := filepath.EvalSymlinks(path); err == nil {
		path = real
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), perm); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

type line struct {
	text, entry, why, section string
	profiles                  []string
	heading                   bool
}

func scan(data []byte) []line {
	raw := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	out := make([]line, len(raw))
	section, blank, top := "", true, true
	var profiles []string
	for n, r := range raw {
		t := strings.TrimSpace(r)
		l := line{text: t}
		switch {
		case t == "":
			blank = true
			l.section, l.profiles = section, profiles
			out[n] = l
			continue
		case strings.HasPrefix(t, "#"):
			if blank && (!top || !fileComment(raw[n:])) {
				section, profiles = heading(strings.TrimLeft(t, "#"))
				l.heading = true
			}
		default:
			l.entry, l.why = split(t)
		}
		blank, top = false, false
		l.section, l.profiles = section, profiles
		out[n] = l
	}
	return out
}

// heading cuts a section heading into its name and the profiles in the
// brackets at its end.
func heading(t string) (string, []string) {
	t = strings.TrimSpace(t)
	open := strings.LastIndex(t, "[")
	if open < 0 || !strings.HasSuffix(t, "]") {
		return t, nil
	}
	var profiles []string
	for p := range strings.SplitSeq(t[open+1:len(t)-1], ",") {
		if p = strings.ToLower(strings.TrimSpace(p)); p != "" && !slices.Contains(profiles, p) {
			profiles = append(profiles, p)
		}
	}
	return strings.TrimSpace(t[:open]), profiles
}

// fileComment reports whether the comment block that starts lines ends in a
// blank line or the end of the file.
func fileComment(lines []string) bool {
	for _, l := range lines {
		if t := strings.TrimSpace(l); !strings.HasPrefix(t, "#") {
			return t == ""
		}
	}
	return true
}

// split cuts a line at its first # outside double quotes.
func split(t string) (entry, why string) {
	quoted := false
	for n, c := range t {
		switch {
		case c == '"':
			quoted = !quoted
		case c == '#' && !quoted:
			return strings.TrimSpace(t[:n]), strings.TrimSpace(t[n+1:])
		}
	}
	return t, ""
}
