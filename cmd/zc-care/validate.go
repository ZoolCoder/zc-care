package main

import (
	"errors"
	"os"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/provider/agents"
)

// validateManifests checks what validate can read offline beyond the config:
// each agents manifest, such as its ${keychain:...} references. A manifest
// that is not there yet is not an error.
func validateManifests(cfg config.Config) error {
	var errs []error
	for _, t := range cfg.Targets {
		if t.Provider != "agents" {
			continue
		}
		file := cfg.Resolve(t).File
		if _, err := os.Stat(file); err != nil {
			continue
		}
		if _, err := agents.Load(file); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
