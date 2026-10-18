// Package starter is the config zc-care init writes for a Mac with no config
// of its own: a Brewfile whose sections are tagged by profile, a mise.toml
// and a zc-care.yaml with a settings target per profile. Every profile's
// part is written, so the same files serve a Mac whose profiles change
// later; the machine's profiles pick what applies.
package starter

import (
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/zoolcoder/zc-care/internal/manifest"
)

//go:embed Brewfile mise.toml zc-care.yaml
var files embed.FS

// Profile is who a Mac is for.
type Profile struct {
	Name  string `json:"name"`
	Title string `json:"title"`
	About string `json:"about"`
}

// Profiles are the ones the starter Brewfile and config have sections for.
var Profiles = []Profile{
	{"everyday", "Everyday", "Browsing, music, messages, video meetings and documents."},
	{"developer", "Developer", "A terminal, git, runtimes, a code editor and containers."},
	{"creative", "Creative", "Design, photos, 3D, audio and screen recording."},
}

// Roles say what a Mac is used for, beside who uses it; a config can tag an
// overlay or a work-only target with one.
var Roles = []string{"personal", "work"}

// Names lists the profile names, in order.
func Names() []string {
	names := make([]string, len(Profiles))
	for i, p := range Profiles {
		names[i] = p.Name
	}
	return names
}

// Options is what init was asked for.
type Options struct {
	// Dir is where the files go.
	Dir string
	// Profiles are who the Mac is for, from Profiles; at least one.
	Profiles []string
	// Captured is a Brewfile of what this Mac has installed. Its entries the
	// starter lacks are kept in a section of their own.
	Captured []byte
	// Force overwrites files that are already there.
	Force bool
}

// Result is what Write did.
type Result struct {
	Config string   `json:"config"`
	Files  []string `json:"files"`
	// Skip lists the packages of other profiles' sections, for the
	// machine's skip list.
	Skip []string `json:"skip"`
	// Kept counts the entries from this Mac added to the Brewfile.
	Kept int `json:"kept"`
}

// kept is the section that holds what this Mac had and the starter lacks.
const kept = "From this Mac"

// Write writes the starter files to o.Dir. It writes nothing when one of
// them is there already, unless forced.
func Write(o Options) (Result, error) {
	if len(o.Profiles) == 0 {
		return Result{}, fmt.Errorf("choose a profile: %s", strings.Join(Names(), ", "))
	}
	for _, p := range o.Profiles {
		if !slices.Contains(Names(), p) {
			return Result{}, fmt.Errorf("profile %q is not one of %s", p, strings.Join(Names(), ", "))
		}
	}
	brewfile, err := files.ReadFile("Brewfile")
	if err != nil {
		return Result{}, err
	}
	brewfile, n := keep(brewfile, o.Captured)
	out := map[string][]byte{"Brewfile": brewfile}
	for _, name := range []string{"mise.toml", "zc-care.yaml"} {
		if out[name], err = files.ReadFile(name); err != nil {
			return Result{}, err
		}
	}

	names := []string{"zc-care.yaml", "Brewfile", "mise.toml"}
	res := Result{Config: filepath.Join(o.Dir, "zc-care.yaml"), Skip: skip(brewfile, o.Profiles), Kept: n}
	for _, name := range names {
		path := filepath.Join(o.Dir, name)
		if _, err := os.Lstat(path); err == nil && !o.Force {
			return Result{}, fmt.Errorf("%s exists; pass -force to replace it, or plan with the config you have", path)
		} else if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return Result{}, err
		}
		res.Files = append(res.Files, path)
	}
	if err := os.MkdirAll(o.Dir, 0o755); err != nil {
		return Result{}, err
	}
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(o.Dir, name), out[name], 0o644); err != nil {
			return Result{}, err
		}
	}
	return res, nil
}

// keep appends captured's entries that brewfile lacks under their own
// heading, and counts them.
func keep(brewfile, captured []byte) ([]byte, int) {
	have := manifest.Notes(brewfile, resource)
	var lines []string
	for line := range strings.Lines(string(captured)) {
		line, _, _ = strings.Cut(strings.TrimSpace(line), " #")
		r, ok := resource(line)
		if !ok {
			continue
		}
		if _, dup := have[r]; dup {
			continue
		}
		have[r] = manifest.Note{}
		lines = append(lines, line+" # on this Mac before zc-care init")
	}
	if len(lines) == 0 {
		return brewfile, 0
	}
	body := strings.TrimRight(string(brewfile), "\n") + "\n\n# " + kept + "\n" + strings.Join(lines, "\n") + "\n"
	return []byte(body), len(lines)
}

// skip lists the packages in sections for none of profiles.
func skip(brewfile []byte, profiles []string) []string {
	var out []string
	for r, note := range manifest.Notes(brewfile, resource) {
		if strings.HasPrefix(r, "tap:") || len(note.Profiles) == 0 {
			continue
		}
		if !slices.ContainsFunc(note.Profiles, func(p string) bool { return slices.Contains(profiles, p) }) {
			out = append(out, r)
		}
	}
	slices.Sort(out)
	return out
}

// resource reads a Brewfile entry as the skip list names it, such as
// cask:ghostty.
func resource(line string) (string, bool) {
	kind, rest, ok := strings.Cut(strings.TrimSpace(line), " ")
	if !ok || !slices.Contains([]string{"tap", "brew", "cask", "mas"}, kind) {
		return "", false
	}
	quoted, _, _ := strings.Cut(rest, ",")
	name, err := strconv.Unquote(strings.TrimSpace(quoted))
	if err != nil || name == "" {
		return "", false
	}
	return kind + ":" + name, true
}
