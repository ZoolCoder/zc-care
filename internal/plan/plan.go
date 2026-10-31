// Package plan holds the ordered list of changes the tool intends to make. It
// performs no I/O: a provider reads live state and hands in actions whose Do
// closures carry the writes.
package plan

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"
	"unicode"
)

type Op string

const (
	OpCreate Op = "CREATE"
	OpUpdate Op = "UPDATE"
	OpDelete Op = "DELETE"
	// OpManual is a change a person must make outside the tool. It renders in
	// the plan but never runs, so a plan that still lists one after an apply
	// is not a failure to converge.
	OpManual Op = "MANUAL"
)

// Action is one intended change. Do performs it and must be idempotent, so a
// rerun after a partial apply is safe. Do is nil exactly when Op is OpManual.
type Action struct {
	Op       Op
	Target   string // the config target the change belongs to
	Resource string // the thing being changed inside the target
	Detail   string // human-readable, never a secret value
	// Digest, when set, fingerprints the content Do will write, so a saved
	// plan notices a source that changed without changing its Detail.
	Digest string
	// Destructive marks a change that is no delete but loses something the
	// tool did not write, such as an edit made outside it, or that runs a
	// script. It needs the same confirmation as a delete.
	Destructive bool
	// Waiting marks a MANUAL that exists only because a program is not
	// installed: once an apply installs it, the target can plan real changes.
	Waiting bool
	// Before, when set, reads the state Do is about to replace, right before
	// it runs, so undo can put it back. A failure does not stop Do.
	Before func(context.Context) (Undo, error)
	Do     func(context.Context) error
}

// MissingProgram is the MANUAL for a target that cannot plan until program
// is installed.
func MissingProgram(target, resource, detail string) Action {
	return Action{Op: OpManual, Target: target, Resource: resource, Detail: detail, Waiting: true}
}

// valid enforces that Do is nil exactly when Op is OpManual.
func (a Action) valid() error {
	if manual := a.Op == OpManual; manual != (a.Do == nil) {
		return fmt.Errorf("invalid action %s %s %s: Do must be nil exactly when Op is %s", a.Op, a.Target, a.Resource, OpManual)
	}
	return nil
}

func (p Plan) validate() error {
	var errs []error
	for _, a := range p.Actions {
		errs = append(errs, a.valid())
	}
	return errors.Join(errs...)
}

func (a Action) destroys() bool { return a.Op == OpDelete || a.Destructive }

type Plan struct {
	Actions []Action
}

func (p *Plan) Add(actions ...Action) { p.Actions = append(p.Actions, actions...) }

func (p Plan) Empty() bool { return len(p.Actions) == 0 }

// sorted is a stable order, so two runs of an unchanged config print the same
// plan and a diff between them means something.
func (p Plan) sorted() []Action {
	out := slices.Clone(p.Actions)
	slices.SortStableFunc(out, func(a, b Action) int {
		return cmp.Or(cmp.Compare(a.Target, b.Target), cmp.Compare(a.Resource, b.Resource))
	})
	return out
}

func (p Plan) filter(keep func(Action) bool) []Action {
	var out []Action
	for _, a := range p.Actions {
		if keep(a) {
			out = append(out, a)
		}
	}
	return out
}

// Only is the plan cut down to the actions on these resources; with none, it
// is the whole plan.
func (p Plan) Only(resources []string) Plan {
	if len(resources) == 0 {
		return p
	}
	return Plan{Actions: p.filter(func(a Action) bool { return slices.Contains(resources, a.Resource) })}
}

// Manual returns the actions no tool can perform.
func (p Plan) Manual() []Action { return p.filter(func(a Action) bool { return a.Op == OpManual }) }

// Executable is what apply will actually run.
func (p Plan) Executable() []Action { return p.filter(func(a Action) bool { return a.Op != OpManual }) }

// Destructive reports whether the plan deletes, overwrites an outside edit or
// runs a script, so a caller can insist on confirmation first.
func (p Plan) Destructive() bool {
	return slices.ContainsFunc(p.Actions, Action.destroys)
}

// Write renders the plan as aligned columns.
func (p Plan) Write(w io.Writer) error {
	if err := p.validate(); err != nil {
		return err
	}
	if p.Empty() {
		_, err := fmt.Fprintln(w, "no changes: everything matches the config")
		return err
	}
	sorted := p.sorted()
	opW, targetW, resW := 0, 0, 0
	for _, a := range sorted {
		opW, targetW, resW = max(opW, len(a.Op)), max(targetW, len(Plain(a.Target))), max(resW, len(Plain(a.Resource)))
	}
	var b strings.Builder
	for _, a := range sorted {
		fmt.Fprintf(&b, "%-*s  %-*s  %-*s  %s\n", opW, string(a.Op), targetW, Plain(a.Target), resW, Plain(a.Resource), Plain(a.Detail))
	}
	if manual := p.Manual(); len(manual) > 0 {
		fmt.Fprintf(&b, "\n%d of these cannot be automated and are yours to do.\n", len(manual))
	}
	_, err := io.WriteString(w, b.String())
	return err
}

// Plain is Clean for one line: it drops line breaks too, so a package
// description cannot forge the row after it.
func Plain(s string) string {
	return strings.ReplaceAll(Clean(s), "\n", "")
}

// Clean drops what Unsafe reports, such as an escape sequence in a package
// name or a command's output. Everything printed from outside goes through
// it or Plain.
func Clean(s string) string {
	return strings.Map(func(r rune) rune {
		if Unsafe(r) {
			return -1
		}
		return r
	}, s)
}

// Unsafe reports a character that steers a terminal or hides what a reader
// sees: C0 and C1 controls, which start escape sequences, the format
// characters that reorder text or make it invisible, the separators that
// break a line, and the selectors and fillers that draw nothing.
func Unsafe(r rune) bool {
	if r == '\t' || r == '\n' {
		return false
	}
	switch r {
	case 0x034f, 0x115f, 0x1160, 0x17b4, 0x17b5, 0x2800, 0x3164, 0xffa0:
		return true
	}
	return unicode.IsControl(r) || unicode.In(r, unicode.Cf, unicode.Zl, unicode.Zp, unicode.Variation_Selector)
}

// JSONAction is one action in the machine-readable plan.
type JSONAction struct {
	Op       string `json:"op"`
	Target   string `json:"target"`
	Resource string `json:"resource"`
	Detail   string `json:"detail"`
	Manual   bool   `json:"manual"`
	// Destructive is true for a delete, an overwrite of an outside edit and a
	// script: what apply asks a person to confirm.
	Destructive bool `json:"destructive"`
}

// WriteJSON renders the plan for a CI step, ZC Care or an agent.
func (p Plan) WriteJSON(w io.Writer) error {
	if err := p.validate(); err != nil {
		return err
	}
	out := struct {
		Changes int          `json:"changes"`
		Manual  int          `json:"manual"`
		Actions []JSONAction `json:"actions"`
	}{Changes: len(p.Executable()), Manual: len(p.Manual()), Actions: []JSONAction{}}
	for _, a := range p.sorted() {
		out.Actions = append(out.Actions, JSONAction{
			Op: string(a.Op), Target: a.Target, Resource: a.Resource, Detail: a.Detail, Manual: a.Op == OpManual, Destructive: a.destroys(),
		})
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(out)
}
