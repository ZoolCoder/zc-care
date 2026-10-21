package settings

import (
	"context"
	"slices"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/plan"
)

// recorded runs each action's Before, as apply does, and returns the records
// newest change first, as the journal hands them to Revert.
func recorded(t *testing.T, actions []plan.Action) []plan.Undo {
	t.Helper()
	var undos []plan.Undo
	for _, a := range actions {
		if a.Before == nil {
			t.Fatalf("%s records nothing", a.Resource)
		}
		u, err := a.Before(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		u.Target, u.Resource = a.Target, a.Resource
		if !u.Nothing() {
			undos = append(undos, u)
		}
	}
	slices.Reverse(undos)
	return undos
}

func TestRevertPutsOldValuesBack(t *testing.T) {
	ctx := context.Background()
	r := machine()
	r.Out[read("NSGlobalDomain", "KeyRepeat")] = "5\n"
	p := Provider{r: r, home: "/Users/me"}
	actions, err := p.Plan(ctx, target())
	if err != nil {
		t.Fatal(err)
	}
	undos := recorded(t, actions)

	r.Ran = nil
	for _, a := range p.Revert(undos) {
		if err := a.Do(ctx); err != nil {
			t.Fatal(err)
		}
	}
	for _, line := range []string{
		// Not set before: the key goes, rather than staying at the new value.
		"defaults delete com.apple.dock autohide",
		"defaults delete com.apple.screencapture location",
		// Set before: the old value comes back with its type.
		"defaults write NSGlobalDomain KeyRepeat -int 5",
		"defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool true",
		"killall Dock",
		"killall SystemUIServer",
	} {
		if !slices.Contains(r.Ran, line) {
			t.Errorf("ran %q, missing %q", r.Ran, line)
		}
	}
}

func TestRevertCannotRestoreACollection(t *testing.T) {
	r := machine()
	r.Out[read("NSGlobalDomain", "KeyRepeat")] = "(\n 1\n)\n"
	r.Out[readType("NSGlobalDomain", "KeyRepeat")] = "Type is array\n"
	p := Provider{r: r, home: "/Users/me"}
	actions, _ := p.Plan(context.Background(), target())
	for _, a := range actions {
		if a.Resource != "NSGlobalDomain KeyRepeat" {
			continue
		}
		u, err := a.Before(context.Background())
		if err != nil || !strings.Contains(u.Reason, "array") {
			t.Fatalf("undo %+v, %v: want a reason naming the type", u, err)
		}
		return
	}
	t.Fatal("no KeyRepeat action")
}
