// Package config reads the YAML file that declares the desired state. It
// reads that file and nothing else, so `validate` runs offline.
package config

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"gopkg.in/yaml.v3"
)

// Version is the config schema this build reads.
const Version = 1

// Providers lists the provider names a target may use. A new provider adds
// its name here and its package under internal/provider.
var Providers = []string{"localdir", "packages", "dotfiles", "tools", "desktop", "settings", "services", "agents"}

// Accents are the macOS accent colours the desktop provider sets.
var Accents = []string{"blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite"}

// Config is the whole file.
type Config struct {
	Version int      `yaml:"version"`
	Targets []Target `yaml:"targets"`
	// Dir is the directory the file was read from; relative target paths
	// resolve against it. Empty for standard input, which resolves against
	// the working directory.
	Dir string `yaml:"-"`
	// Skip is this machine's skip list, from SkipPath; Resolve hands it to
	// every target.
	Skip []string `yaml:"-"`
	// Profiles is who this machine is for, from ProfilesPath; a target
	// with profiles applies only when one of them is here.
	Profiles []string `yaml:"-"`
}

// Target is one thing to reconcile.
type Target struct {
	Name     string `yaml:"name"`
	Provider string `yaml:"provider"`
	// File is the manifest: a Brewfile, a mise config or an agents file.
	File string `yaml:"file"`
	// Upgrade makes plan upgrade declared packages or runtimes that have a
	// newer version, not only install the missing ones.
	Upgrade bool `yaml:"upgrade"`
	// Source is the chezmoi source directory the dotfiles provider applies.
	Source string `yaml:"source"`
	// Destination is where dotfiles land; empty means the home directory.
	Destination string `yaml:"destination"`
	// Mode is chezmoi's mode: file (copies, the default) or symlink.
	Mode string `yaml:"mode"`
	// Path is the directory the localdir provider manages.
	Path string `yaml:"path"`
	// Prune deletes files in Path that the config does not declare.
	Prune bool `yaml:"prune"`
	// Files maps a path relative to Path to the content it should hold.
	Files map[string]string `yaml:"files"`
	// Wallpaper is the picture the desktop provider sets on every desktop.
	Wallpaper string `yaml:"wallpaper"`
	// Screensaver is the web page the desktop provider has WebViewScreenSaver
	// show.
	Screensaver string `yaml:"screensaver"`
	// Accent is the macOS accent colour the desktop provider sets, one of
	// Accents.
	Accent string `yaml:"accent"`
	// Defaults maps a macOS preferences domain, such as com.apple.dock or
	// NSGlobalDomain, to the keys the settings provider keeps and their
	// values: a bool, an integer, a number or a string.
	Defaults map[string]map[string]any `yaml:"defaults"`
	// Services are the Homebrew services the services provider keeps running.
	Services []string `yaml:"services"`
	// Agents are the launchd agent plists the services provider keeps
	// loaded.
	Agents []string `yaml:"agents"`
	// Profiles limits the target to machines with one of these profiles,
	// such as developer or work; empty is every machine.
	Profiles []string `yaml:"profiles"`
	// Skip lists the resources, such as cask:ghostty, this machine does not
	// install. The packages provider reads it; it is never in the YAML.
	Skip []string `yaml:"-"`
}

// Root is the target's directory, resolved against the config's directory.
func (c Config) Root(t Target) string { return c.resolve(t.Path) }

// Resolve returns t with every path made absolute: ~ is the home directory,
// and a relative path is relative to the config's directory.
func (c Config) Resolve(t Target) Target {
	t.Path, t.File, t.Source = c.resolve(t.Path), c.resolve(t.File), c.resolve(t.Source)
	t.Destination = c.resolve(t.Destination)
	t.Wallpaper, t.Screensaver = c.resolve(t.Wallpaper), c.resolve(t.Screensaver)
	t.Skip = c.Skip
	agents := make([]string, len(t.Agents))
	for i, a := range t.Agents {
		agents[i] = c.resolve(a)
	}
	if t.Agents != nil {
		t.Agents = agents
	}
	return t
}

func (c Config) resolve(p string) string {
	switch {
	case p == "":
		return ""
	case p == "~" || strings.HasPrefix(p, "~/"):
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[1:])
		}
		return p
	case filepath.IsAbs(p):
		return p
	}
	return filepath.Join(c.Dir, p)
}

// Where is what the target reads: its manifest, chezmoi source or directory.
func (t Target) Where() string {
	switch {
	case t.Source != "":
		return t.Source
	case t.File != "":
		return t.File
	}
	return t.Path
}

// Names lists the target names in file order.
func (c Config) Names() []string {
	names := make([]string, 0, len(c.Targets))
	for _, t := range c.Targets {
		names = append(names, t.Name)
	}
	return names
}

// Find returns the named target.
func (c Config) Find(name string) (Target, bool) {
	for _, t := range c.Targets {
		if t.Name == name {
			return t, true
		}
	}
	return Target{}, false
}

// Load reads path, or standard input when path is "-", and this machine's
// skip list.
func Load(path string, stdin io.Reader) (Config, error) {
	var (
		data []byte
		err  error
		dir  string
	)
	if path == "-" {
		data, err = io.ReadAll(stdin)
	} else {
		if dir, err = filepath.Abs(filepath.Dir(path)); err == nil {
			data, err = os.ReadFile(path)
		}
	}
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	cfg, err := Parse(data)
	if err != nil {
		return Config{}, fmt.Errorf("%s: %w", path, err)
	}
	cfg.Dir = dir
	if cfg.Skip, err = ReadSkip(SkipPath()); err != nil {
		return Config{}, err
	}
	if cfg.Profiles, err = ReadProfiles(ProfilesPath()); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// Parse decodes and validates a config. Unknown keys are refused: a typo
// that is silently ignored is a setting that silently does nothing.
func Parse(data []byte) (Config, error) {
	var cfg Config
	dec := yaml.NewDecoder(bytes.NewReader(data))
	dec.KnownFields(true)
	if err := dec.Decode(&cfg); err != nil && !errors.Is(err, io.EOF) {
		return Config{}, err
	}
	cfg.cleanFileNames()
	return cfg, cfg.Validate()
}

// cleanFileNames rewrites each localdir file name to its clean form, so
// ./a.txt and a.txt are one file. A name that clashes with another after
// cleaning is left for Validate to report.
func (c *Config) cleanFileNames() {
	for i, t := range c.Targets {
		if t.Provider != "localdir" || len(t.Files) == 0 {
			continue
		}
		cleaned := make(map[string]string, len(t.Files))
		for name, content := range t.Files {
			cleaned[filepath.Clean(name)] = content
		}
		if len(cleaned) == len(t.Files) {
			c.Targets[i].Files = cleaned
		}
	}
}

var kebab = regexp.MustCompile(`^[a-z][a-z0-9]*(-[a-z0-9]+)*$`)

// Validate reports every problem at once, so one run fixes the file.
func (c Config) Validate() error {
	var errs []error
	if c.Version != Version {
		errs = append(errs, fmt.Errorf("version is %d, this build reads version %d", c.Version, Version))
	}
	seen := map[string]bool{}
	for i, t := range c.Targets {
		where := fmt.Sprintf("targets[%d]", i)
		if t.Name != "" {
			where = "target " + t.Name
		}
		switch {
		case !kebab.MatchString(t.Name):
			errs = append(errs, fmt.Errorf("%s: name %q must be kebab-case", where, t.Name))
		case seen[t.Name]:
			errs = append(errs, fmt.Errorf("%s: declared twice", where))
		}
		seen[t.Name] = true
		for _, p := range t.Profiles {
			if !IsProfile(p) {
				errs = append(errs, fmt.Errorf("%s: profile %q must be kebab-case", where, p))
			}
		}
		if !slices.Contains(Providers, t.Provider) {
			errs = append(errs, fmt.Errorf("%s: provider %q is not one of %s", where, t.Provider, strings.Join(Providers, ", ")))
		} else {
			errs = append(errs, t.validateFields(where)...)
		}
	}
	return errors.Join(errs...)
}

// fieldCheck collects the problems with one target's fields.
type fieldCheck struct {
	where, provider string
	errs            []error
}

func (c *fieldCheck) add(format string, args ...any) {
	c.errs = append(c.errs, fmt.Errorf("%s: %s", c.where, fmt.Sprintf(format, args...)))
}

func (c *fieldCheck) need(field, value string) {
	if value == "" {
		c.add("%s is required for provider %s", field, c.provider)
	}
}

func (c *fieldCheck) unused(field string, set bool) {
	if set {
		c.add("%s does nothing for provider %s", field, c.provider)
	}
}

// validateFields checks the fields each provider needs, and refuses the ones
// it would ignore.
func (t Target) validateFields(where string) []error {
	c := &fieldCheck{where: where, provider: t.Provider}
	switch t.Provider {
	case "localdir":
		t.checkLocaldir(c)
	case "packages":
		c.need("file", t.File)
	case "dotfiles":
		t.checkDotfiles(c)
	case "tools", "agents":
		c.need("file", t.File)
	case "desktop":
		t.checkDesktop(c)
	case "settings":
		t.checkSettings(c)
	case "services":
		t.checkServices(c)
	}
	t.checkUnused(c)
	return c.errs
}

func (t Target) checkLocaldir(c *fieldCheck) {
	c.need("path", t.Path)
	// Names differ in case on a case-sensitive disk only; APFS is usually
	// case-insensitive, and a.txt with A.txt there is one file. Not checked.
	cleaned := map[string]string{}
	for _, name := range slices.Sorted(maps.Keys(t.Files)) {
		clean := filepath.Clean(name)
		switch {
		case !filepath.IsLocal(name) || clean == ".":
			c.add("file %q must stay inside the target path", name)
		case cleaned[clean] != "":
			c.add("files %q and %q are the same file", cleaned[clean], name)
		default:
			cleaned[clean] = name
		}
	}
}

func (t Target) checkDotfiles(c *fieldCheck) {
	c.need("source", t.Source)
	if t.Mode != "" && t.Mode != "file" && t.Mode != "symlink" {
		c.add("mode %q is not file or symlink", t.Mode)
	}
}

func (t Target) checkDesktop(c *fieldCheck) {
	if t.Wallpaper == "" && t.Screensaver == "" && t.Accent == "" {
		c.add("set wallpaper, screensaver or accent for provider desktop")
	}
	if t.Accent != "" && !slices.Contains(Accents, t.Accent) {
		c.add("accent %q is not one of %s", t.Accent, strings.Join(Accents, ", "))
	}
}

func (t Target) checkSettings(c *fieldCheck) {
	if len(t.Defaults) == 0 {
		c.add("defaults is required for provider settings")
	}
	for domain, keys := range t.Defaults {
		for name, v := range keys {
			switch v.(type) {
			case bool, int, float64, string:
			default:
				c.add("%s %s must be a bool, number or string", domain, name)
			}
		}
	}
}

func (t Target) checkServices(c *fieldCheck) {
	if len(t.Services) == 0 && len(t.Agents) == 0 {
		c.add("set services or agents for provider services")
	}
	for _, a := range t.Agents {
		if filepath.Ext(a) != ".plist" {
			c.add("agent %q must be a launchd .plist file", a)
		}
	}
}

// checkUnused refuses the fields that belong to another provider.
func (t Target) checkUnused(c *fieldCheck) {
	if t.Provider != "localdir" {
		c.unused("path", t.Path != "")
		c.unused("files", len(t.Files) > 0)
		c.unused("prune", t.Prune)
	}
	if t.Provider != "packages" && t.Provider != "tools" {
		c.unused("upgrade", t.Upgrade)
	}
	if t.Provider != "dotfiles" {
		c.unused("source", t.Source != "")
		c.unused("destination", t.Destination != "")
		c.unused("mode", t.Mode != "")
	}
	if !slices.Contains([]string{"packages", "tools", "agents"}, t.Provider) {
		c.unused("file", t.File != "")
	}
	if t.Provider != "desktop" {
		c.unused("wallpaper", t.Wallpaper != "")
		c.unused("screensaver", t.Screensaver != "")
		c.unused("accent", t.Accent != "")
	}
	if t.Provider != "settings" {
		c.unused("defaults", len(t.Defaults) > 0)
	}
	if t.Provider != "services" {
		c.unused("services", len(t.Services) > 0)
		c.unused("agents", len(t.Agents) > 0)
	}
}
