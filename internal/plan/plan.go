// Package plan holds the ordered list of changes the tool intends to make. It
// performs no I/O: a provider reads live state and hands in actions whose Do
// closures carry the writes.
package plan

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"slices"
	"strings"
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
	// Destructive marks a change that is no delete but loses something the
	// tool did not write, such as an edit made outside it, or that runs a
	// script. It needs the same confirmation as a delete.
	Destructive bool
	Do          func(context.Context) error
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
	if p.Empty() {
		_, err := fmt.Fprintln(w, "no changes: everything matches the config")
		return err
	}
	sorted := p.sorted()
	opW, targetW, resW := 0, 0, 0
	for _, a := range sorted {
		opW, targetW, resW = max(opW, len(a.Op)), max(targetW, len(a.Target)), max(resW, len(a.Resource))
	}
	var b strings.Builder
	for _, a := range sorted {
		fmt.Fprintf(&b, "%-*s  %-*s  %-*s  %s\n", opW, string(a.Op), targetW, a.Target, resW, a.Resource, a.Detail)
	}
	if manual := p.Manual(); len(manual) > 0 {
		fmt.Fprintf(&b, "\n%d of these cannot be automated and are yours to do.\n", len(manual))
	}
	_, err := io.WriteString(w, b.String())
	return err
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
