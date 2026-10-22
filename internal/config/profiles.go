package config

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// EnvProfiles names a profiles file other than the default one.
const EnvProfiles = "ZC_CARE_PROFILES"

// ProfilesPath is this machine's profiles file: who the Mac is for, such as
// developer, and its role, such as work. Like the skip list it lives beside
// the user's config, so one config serves several Macs.
func ProfilesPath() string {
	if p := os.Getenv(EnvProfiles); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "zc-care", "profiles")
}

// ReadProfiles lists the profiles in a profiles file. No file is an empty
// list, and an empty list means every target is for this machine.
func ReadProfiles(path string) ([]string, error) {
	if path == "" {
		return nil, nil
	}
	names, err := readList(path, "profiles")
	if err != nil {
		return nil, err
	}
	for n, name := range names {
		names[n] = strings.ToLower(name)
		if !IsProfile(names[n]) {
			return nil, fmt.Errorf("profiles file %s: %q must be kebab-case, such as developer or work", path, name)
		}
	}
	slices.Sort(names)
	return slices.Compact(names), nil
}

// WriteProfiles replaces the profiles file with profiles.
func WriteProfiles(path string, profiles []string) error {
	return writeList(path, "profiles", "# Who this machine is for; zc-care profile manages it.\n", profiles)
}

// IsProfile reports whether name can be a profile: kebab-case, such as
// developer or work.
func IsProfile(name string) bool { return kebab.MatchString(name) }

// For reports whether the target is for a machine with these profiles: a
// target without profiles is for every machine, and so is every target on a
// machine without profiles.
func (t Target) For(machine []string) bool {
	if len(t.Profiles) == 0 || len(machine) == 0 {
		return true
	}
	return slices.ContainsFunc(t.Profiles, func(p string) bool { return slices.Contains(machine, p) })
}
