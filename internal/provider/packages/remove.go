package packages

import (
	"context"
	"fmt"
	"regexp"
	"slices"
	"strings"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/manifest"
	"github.com/zoolcoder/zc-care/internal/plan"
)

var appID = regexp.MustCompile(`^\d+$`)

// PlanRemove plans the uninstall of kind:name and the drop of its line from
// t's manifest, as one DELETE. An item the manifest does not declare is still
// uninstalled, so leftovers go through the tool too; an App Store app that is
// not declared is named by its id.
func (p Provider) PlanRemove(t config.Target, kind, name string) (plan.Action, error) {
	if kind == "" {
		kind = "brew"
	}
	if !slices.Contains([]string{"brew", "cask", "tap", "mas"}, kind) {
		return plan.Action{}, fmt.Errorf("cannot remove a %q; an item is brew, cask, tap or mas", kind)
	}
	if kind != "mas" && !packageName.MatchString(name) {
		return plan.Action{}, fmt.Errorf("%q is not a package name", name)
	}
	data, err := readFile(t.File)
	if err != nil {
		return plan.Action{}, err
	}
	items, _, err := brew.parse(data)
	if err != nil {
		return plan.Action{}, fmt.Errorf("%s: %w", t.File, err)
	}
	i := item{Kind: kind, Name: name, ID: name}
	declared := false
	for _, d := range items {
		if d.Kind == kind && strings.EqualFold(d.Name, name) {
			i, declared = d, true
		}
	}
	if kind == "mas" && !declared && !appID.MatchString(name) {
		return plan.Action{}, fmt.Errorf("%q is not declared in %s; name an App Store app that is not declared by its numeric id", name, t.File)
	}
	detail := "uninstall with " + installer(i)
	if declared {
		detail += " and drop it from " + t.File
	}
	return plan.Action{
		Op: plan.OpDelete, Target: t.Name, Resource: i.resource(), Detail: detail,
		Do: func(ctx context.Context) error { return p.uninstall(ctx, t, i) },
	}, nil
}

func (p Provider) uninstall(ctx context.Context, t config.Target, i item) error {
	if err := brew.remove(p.r, i)(ctx); err != nil {
		return err
	}
	data, err := readFile(t.File)
	if err != nil {
		return err
	}
	if dropped, ok := manifest.Drop(data, brew.key, i.resource()); ok {
		return writeFile(t.File, dropped)
	}
	return nil
}
