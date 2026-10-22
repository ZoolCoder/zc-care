package main

import (
	"fmt"
	"io"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/plan"
)

// applyChange is one resource in the -json result of apply.
type applyChange struct {
	Target   string `json:"target"`
	Resource string `json:"resource"`
	Error    string `json:"error,omitempty"`
	Detail   string `json:"detail,omitempty"`
}

// applyResult is what apply -json prints: what changed, what failed, what is
// left for a person, and whether the run converged.
type applyResult struct {
	Applied     []applyChange `json:"applied"`
	Failed      []applyChange `json:"failed"`
	Outstanding []applyChange `json:"outstanding"`
	Verified    bool          `json:"verified"`
}

// writeApplied prints the -json result of an apply; without -json it prints
// nothing, since the plan and progress already told the story. runErr is the
// error of the run, nil when it converged and was verified.
func (f cliFlags) writeApplied(w io.Writer, p plan.Plan, outcomes []engine.Outcome, runErr error) error {
	if !f.asJSON {
		return nil
	}
	r := applyResult{Applied: []applyChange{}, Failed: []applyChange{}, Outstanding: []applyChange{}}
	for _, o := range outcomes {
		if o.Err != nil {
			r.Failed = append(r.Failed, applyChange{Target: o.Target, Resource: o.Resource, Error: o.Err.Error()})
			continue
		}
		r.Applied = append(r.Applied, applyChange{Target: o.Target, Resource: o.Resource})
	}
	for _, a := range p.Manual() {
		r.Outstanding = append(r.Outstanding, applyChange{Target: a.Target, Resource: a.Resource, Detail: a.Detail})
	}
	r.Verified = runErr == nil && len(r.Outstanding) == 0
	return writeJSON(w, r)
}

// validateResult is what validate -json prints.
type validateResult struct {
	Config  string   `json:"config"`
	Targets int      `json:"targets"`
	Valid   bool     `json:"valid"`
	Errors  []string `json:"errors"`
}

// runValidate reports whether the config, and the manifests it names, are
// valid. loadErr is the error of loading the config.
func runValidate(f cliFlags, cfg config.Config, loadErr error, stdout io.Writer) error {
	err := loadErr
	if err == nil {
		err = validateManifests(cfg)
	}
	if f.asJSON {
		r := validateResult{Config: f.path, Targets: len(cfg.Targets), Valid: err == nil, Errors: errorTexts(err)}
		if werr := writeJSON(stdout, r); werr != nil {
			return werr
		}
		return err
	}
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(stdout, "%s: %d target(s), valid\n", f.path, len(cfg.Targets))
	return err
}

// errorTexts is the message of each error err joins; empty for nil.
func errorTexts(err error) []string {
	out := []string{}
	if err == nil {
		return out
	}
	joined, ok := err.(interface{ Unwrap() []error }) //nolint:errorlint // only a direct join has its parts listed
	if !ok {
		return append(out, err.Error())
	}
	for _, inner := range joined.Unwrap() {
		out = append(out, inner.Error())
	}
	return out
}
