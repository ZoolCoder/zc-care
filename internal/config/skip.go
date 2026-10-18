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
func ReadSkip(path string) ([]string, error) {
	if path == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read skip list: %w", err)
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
	resources = slices.Clone(resources)
	slices.Sort(resources)
	resources = slices.Compact(resources)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("write skip list: %w", err)
	}
	var body strings.Builder
	body.WriteString("# Packages this machine does not install; zc-care skip manages it.\n")
	for _, r := range resources {
		body.WriteString(r)
		body.WriteByte('\n')
	}
	if err := os.WriteFile(path, []byte(body.String()), 0o644); err != nil {
		return fmt.Errorf("write skip list: %w", err)
	}
	return nil
}
