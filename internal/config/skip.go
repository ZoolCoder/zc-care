package config

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// EnvSkip names a skip file other than the default one.
const EnvSkip = "ZC_CARE_SKIP"

// SkipPath is this machine's skip file: the packages the config declares
// that the owner chose not to install here. It lives beside the user's
// config, not in the config repository, so other machines still get them.
func SkipPath() string {
	if p := os.Getenv(EnvSkip); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "zc-care", "skip")
}

// ReadSkip lists the resources in a skip file, such as cask:ghostty, one a
// line; # starts a comment. No file is an empty list.
func ReadSkip(path string) ([]string, error) { return readList(path, "skip list") }

// readList reads a file of one name a line; # starts a comment.
func readList(path, what string) ([]string, error) {
	if path == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", what, err)
	}
	var out []string
	for line := range strings.Lines(string(data)) {
		line, _, _ = strings.Cut(line, "#")
		if line = strings.TrimSpace(line); line != "" {
			out = append(out, line)
		}
	}
	slices.Sort(out)
	return slices.Compact(out), nil
}

// WriteSkip replaces the skip file with resources, sorted and once each.
func WriteSkip(path string, resources []string) error {
	return writeList(path, "skip list", "# Packages this machine does not install; zc-care skip manages it.\n", resources)
}

// writeList replaces the file with head and the names, sorted and once each.
func writeList(path, what, head string, names []string) error {
	names = slices.Clone(names)
	slices.Sort(names)
	names = slices.Compact(names)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("write %s: %w", what, err)
	}
	var body strings.Builder
	body.WriteString(head)
	for _, r := range names {
		body.WriteString(r)
		body.WriteByte('\n')
	}
	if err := os.WriteFile(path, []byte(body.String()), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", what, err)
	}
	return nil
}
