package packages

import (
	"fmt"
	"os"
	"regexp"
	"strings"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/manifest"
	"github.com/zoolcoder/zc-care/internal/provider"
)

var packageName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9@._+/-]*$`)

// Add declares e in t's manifest: under e.Section, with e.Why at the end of
// its line. A formula or cask from a tap the Brewfile does not declare brings
// its tap line too, since Homebrew installs from a tap only once it is
// trusted.
func (p Provider) Add(t config.Target, e provider.Entry) error {
	if !packageName.MatchString(e.Name) {
		return fmt.Errorf("%q is not a package name", e.Name)
	}
	kind, entry, err := brew.entry(e.Kind, e.Name)
	if err != nil {
		return err
	}
	line, err := manifest.Line(entry, e.Why)
	if err != nil {
		return err
	}
	data, err := readFile(t.File)
	if err != nil {
		return err
	}
	items, _, err := brew.parse(data)
	if err != nil {
		return fmt.Errorf("%s: %w", t.File, err)
	}
	if declares(items, kind, e.Name) {
		return fmt.Errorf("%s already declares %s %s", t.File, kind, e.Name)
	}
	if sections := manifest.Sections(data); e.Section == "" && len(sections) > 0 {
		return fmt.Errorf("choose a section: %s, or a new one", strings.Join(sections, ", "))
	}
	if data, err = manifest.Insert(data, e.Section, line); err != nil {
		return err
	}
	if tap := tapOf(e.Name); kind != "tap" && tap != "" && !declares(items, "tap", tap) {
		if data, err = manifest.Insert(data, "", `tap "`+tap+`" # `+e.Name[len(tap)+1:]); err != nil {
			return err
		}
	}
	return writeFile(t.File, data)
}

func declares(items []item, kind, name string) bool {
	for _, i := range items {
		if i.Kind == kind && strings.EqualFold(i.Name, name) {
			return true
		}
	}
	return false
}

// tapOf is the tap in a full name such as owner/tap/formula.
func tapOf(name string) string {
	if parts := strings.Split(name, "/"); len(parts) == 3 {
		return parts[0] + "/" + parts[1]
	}
	return ""
}

// writeFile replaces path's contents and keeps its mode.
func writeFile(path string, data []byte) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	return manifest.WriteFile(path, data, info.Mode().Perm())
}
