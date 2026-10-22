package packages

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/sh"
)

const providerName = "packages"

// applicationsDirs are where a cask's .app lands, the system folder and the
// user's own; a var so tests can point it at a temp folder.
var applicationsDirs = func() []string {
	dirs := []string{"/Applications"}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, "Applications"))
	}
	return dirs
}()

// beforeInstall and beforeRemove need no read of their own: the change itself
// says what the inverse is. A cask install is the exception. It adopts an app
// already in /Applications or ~/Applications, and uninstalling that would delete the user's app.
func beforeInstall(r sh.Runner, i item) func(context.Context) (plan.Undo, error) {
	return func(ctx context.Context) (plan.Undo, error) {
		if i.Kind == "cask" {
			adopted, err := adoptsExistingApp(ctx, r, i.Name)
			if err != nil {
				return plan.Undo{}, err
			}
			if adopted {
				return plan.Irreversible("adopted an existing app"), nil
			}
		}
		return packageUndo("uninstall", i), nil
	}
}

// adoptsExistingApp reports whether a .app the cask installs is there already.
func adoptsExistingApp(ctx context.Context, r sh.Runner, cask string) (bool, error) {
	out, err := r.Output(ctx, "brew", "info", "--cask", "--json=v2", "--", cask)
	if err != nil {
		return false, err
	}
	var info struct {
		Casks []struct {
			Artifacts []struct {
				App []any `json:"app"`
			} `json:"artifacts"`
		} `json:"casks"`
	}
	if err := json.Unmarshal(out, &info); err != nil {
		return false, err
	}
	for _, c := range info.Casks {
		for _, a := range c.Artifacts {
			for _, v := range a.App {
				name, ok := v.(string)
				if !ok || !strings.HasSuffix(name, ".app") {
					continue
				}
				for _, dir := range applicationsDirs {
					if _, err := os.Lstat(filepath.Join(dir, filepath.Base(name))); err == nil {
						return true, nil
					}
				}
			}
		}
	}
	return false, nil
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
