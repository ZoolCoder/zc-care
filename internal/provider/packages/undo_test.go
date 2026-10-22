package packages

import (
	"context"
	"slices"
	"testing"

	"github.com/zoolcoder/zc-care/internal/plan"
)

func TestRevertUninstallsWhatWasInstalledAndReinstallsWhatWasRemoved(t *testing.T) {
	r := brewMachine()
	p := New(r)
	undos := []plan.Undo{
		{Provider: "packages", Target: "pkgs", Resource: "cask ghostty", Verb: "uninstall", Data: map[string]string{"kind": "cask", "name": "ghostty"}},
		{Provider: "packages", Target: "pkgs", Resource: "brew git", Verb: "install", Data: map[string]string{"kind": "brew", "name": "git"}},
	}
	actions := p.Revert(undos)
	if len(actions) != 2 || actions[0].Op != plan.OpDelete || actions[1].Op != plan.OpCreate {
		t.Fatalf("actions %+v", actions)
	}
	for _, a := range actions {
		if err := a.Do(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	want := []string{"brew uninstall --cask -- ghostty", "brew install -- git"}
	if !slices.Equal(r.Ran, want) {
		t.Fatalf("ran %q, want %q", r.Ran, want)
	}
}

func TestAnUpgradeCannotBeUndone(t *testing.T) {
	u, err := beforeUpgrade(context.Background())
	if err != nil || u.Reason == "" {
		t.Fatalf("undo %+v, %v", u, err)
	}
}

func TestRemoveRecordsAReinstall(t *testing.T) {
	u, err := beforeRemove(item{Kind: "mas", Name: "Xcode", ID: "497799835"})(context.Background())
	if err != nil || u.Verb != "install" || u.Provider != "packages" ||
		u.Data["kind"] != "mas" || u.Data["name"] != "Xcode" || u.Data["id"] != "497799835" {
		t.Fatalf("undo %+v, %v", u, err)
	}
}
