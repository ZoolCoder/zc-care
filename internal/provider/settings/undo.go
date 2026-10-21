package settings

import (
	"context"
	"fmt"
	"maps"
	"slices"
	"strconv"

	"github.com/zoolcoder/zc-care/internal/plan"
)

const providerName = "settings"

// before records what a key holds now: its value and type, or that it is not
// set. Only the plain types come back; an array or dictionary cannot be
// written back from the text defaults prints.
func (p Provider) before(ctx context.Context, domain, key string) (plan.Undo, error) {
	have, typ, present, err := p.current(ctx, domain, key)
	if err != nil {
		return plan.Undo{}, err
	}
	u := plan.Undo{Provider: providerName, Verb: "restore", Data: map[string]string{"domain": domain, "key": key}}
	if !present {
		u.Verb = "delete"
		return u, nil
	}
	u.Data["value"], u.Data["type"] = have, typ
	if _, err := restoreArgs(u.Data); err != nil {
		return plan.Irreversible(err.Error()), nil
	}
	return u, nil
}

// restoreArgs are the defaults write arguments that store a recorded value
// with the type it had.
func restoreArgs(d map[string]string) ([]string, error) {
	args := []string{"write", d["domain"], d["key"]}
	switch d["type"] {
	case "Type is boolean":
		return append(args, "-bool", strconv.FormatBool(d["value"] == "1")), nil
	case "Type is integer":
		return append(args, "-int", d["value"]), nil
	case "Type is float":
		return append(args, "-float", d["value"]), nil
	case "Type is string":
		return append(args, "-string", d["value"]), nil
	}
	return nil, fmt.Errorf("the old value was not a plain boolean, number or string (%s)", d["type"])
}

// Revert writes each recorded value back, or deletes a key that was not set,
// then restarts the processes that read the changed domains once.
func (p Provider) Revert(undos []plan.Undo) []plan.Action {
	var actions []plan.Action
	restart := map[string]string{}
	for _, u := range undos {
		a := plan.Action{Op: plan.OpUpdate, Target: u.Target, Resource: u.Resource}
		if u.Verb == "delete" {
			a.Op, a.Detail = plan.OpDelete, "delete the key: it was not set before"
			a.Do = func(ctx context.Context) error {
				return p.r.Run(ctx, "defaults", "delete", u.Data["domain"], u.Data["key"])
			}
		} else {
			args, err := restoreArgs(u.Data)
			if err != nil {
				actions = append(actions, plan.Action{Op: plan.OpManual, Target: u.Target, Resource: u.Resource, Detail: "cannot be undone: " + err.Error()})
				continue
			}
			a.Detail = "restore " + u.Data["value"]
			a.Do = func(ctx context.Context) error { return p.r.Run(ctx, "defaults", args...) }
		}
		actions = append(actions, a)
		if proc, ok := restarts[u.Data["domain"]]; ok {
			restart[proc] = u.Target
		}
	}
	for _, proc := range slices.Sorted(maps.Keys(restart)) {
		actions = append(actions, p.restartAction(restart[proc], proc))
	}
	return actions
}
