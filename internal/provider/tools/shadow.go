package tools

import (
	"context"
	"os"
	"path/filepath"
	"strings"

	"github.com/zoolcoder/zc-care/internal/sh"
)

// Shadow is a command mise provides that the shell does not run from mise:
// Got is the copy found first on PATH, or empty when there is none.
type Shadow struct{ Name, Want, Got string }

// Shadowed checks each command in the bin folders of the tools active in dir.
// The first folder that has a command is the copy mise means; a mise shim
// counts as that copy.
func Shadowed(ctx context.Context, r sh.Runner, dir string, lookPath func(string) (string, error)) ([]Shadow, error) {
	out, err := r.Output(ctx, "mise", "bin-paths", "-C", dir)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var shadows []Shadow
	for line := range strings.Lines(string(out)) {
		bin := strings.TrimSpace(line)
		entries, err := os.ReadDir(bin)
		if bin == "" || err != nil {
			continue
		}
		for _, e := range entries {
			name, want := e.Name(), filepath.Join(bin, e.Name())
			if seen[name] || !executable(want) {
				continue
			}
			seen[name] = true
			got, err := lookPath(name)
			if err != nil {
				got = ""
			}
			if got != want && filepath.Base(filepath.Dir(got)) != "shims" {
				shadows = append(shadows, Shadow{Name: name, Want: want, Got: got})
			}
		}
	}
	return shadows, nil
}

// executable reports whether path, or what a link at path points to, is a
// file anyone may run.
func executable(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	return info.Mode().Perm()&0o111 != 0
}
