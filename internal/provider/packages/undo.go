package packages

import (
	"context"

	"github.com/zoolcoder/zc-care/internal/plan"
)

const providerName = "packages"

// beforeInstall and beforeRemove need no read: the change itself says what
// the inverse is. They are Before hooks so apply records it.
func beforeInstall(i item) func(context.Context) (plan.Undo, error) {
	return func(context.Context) (plan.Undo, error) { return packageUndo("uninstall", i), nil }
}

func beforeRemove(i item) func(context.Context) (plan.Undo, error) {
	return func(context.Context) (plan.Undo, error) { return packageUndo("install", i), nil }
}

// beforeUpgrade records that an upgrade stays: going back a version is not
// something brew does safely.
func beforeUpgrade(context.Context) (plan.Undo, error) {
	return plan.Irreversible("an upgrade is not downgraded"), nil
}

func packageUndo(verb string, i item) plan.Undo {
	return plan.Undo{Provider: providerName, Verb: verb, Data: map[string]string{"kind": i.Kind, "name": i.Name, "id": i.ID}}
}

// Revert uninstalls what apply installed and reinstalls what it removed. An
// uninstall leaves the manifest as it is, so the next plan installs the
// package again; a reinstall does not put its line back in the manifest.
func (p Provider) Revert(undos []plan.Undo) []plan.Action {
	actions := make([]plan.Action, 0, len(undos))
	for _, u := range undos {
		i := item{Kind: u.Data["kind"], Name: u.Data["name"], ID: u.Data["id"]}
		a := plan.Action{Op: plan.OpCreate, Target: u.Target, Resource: u.Resource,
			Detail: "reinstall with " + installer(i) + "; add it to the manifest again if you want it declared",
			Do:     brew.install(p.r, i)}
		if u.Verb == "uninstall" {
			a.Op, a.Detail, a.Do = plan.OpDelete, "uninstall with "+installer(i)+"; the manifest still declares it", brew.remove(p.r, i)
		}
		actions = append(actions, a)
	}
	return actions
}
