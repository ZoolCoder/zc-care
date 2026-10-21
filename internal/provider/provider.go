// Package provider is the seam between the engine and a live system. A
// provider reads live state and returns the actions that would make it match
// a target; each action's Do closure carries the write.
//
// Add a provider: implement Provider in a package under internal/provider,
// add its name to config.Providers, and register it in engine.Default.
package provider

import (
	"context"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/manifest"
	"github.com/zoolcoder/zc-care/internal/plan"
)

// Provider reconciles one kind of target. The engine hands it a target whose
// paths are already resolved against the config file's directory.
type Provider interface {
	// Plan compares live state with t and returns what would change. It must
	// not write.
	Plan(ctx context.Context, t config.Target) ([]plan.Action, error)
	// Measure counts what is in place, so status and ZC Care can show
	// progress; Live.Summary is the one-line form.
	Measure(ctx context.Context, t config.Target) (Live, error)
}

// Live is a target's measured state: how many of the items it declares are
// in place.
type Live struct {
	InPlace, Declared int
	Summary           string
}

// Requirer is a Provider that runs other programs; doctor shows whether
// each is installed.
type Requirer interface {
	Programs(t config.Target) []string
}

// An item's state on this machine.
const (
	InPlace = "in place"
	Missing = "missing"
	Differs = "differs"
	Manual  = "manual"
	// Outdated is in place, with a newer version available.
	Outdated = "outdated"
	// Extra is installed on purpose but declared by no target.
	Extra = "not declared"
	// Skipped is declared, missing, and on this machine's skip list.
	Skipped = "skipped"
)

// Item is one thing a target declares, with what this machine says about it.
// Only Name, Kind and State are always set.
type Item struct {
	Name  string `json:"name"`
	Kind  string `json:"kind"`
	State string `json:"state"`
	// Version is what is installed, when that can be read.
	Version string `json:"version,omitempty"`
	// Latest is the newer version an outdated item can move to.
	Latest string `json:"latest,omitempty"`
	// App is what the item belongs to: the application a cask installs, or
	// the program a dotfile configures.
	App      string `json:"app,omitempty"`
	Desc     string `json:"desc,omitempty"`
	Homepage string `json:"homepage,omitempty"`
	// Section and Why come from the manifest's comments: the heading the
	// entry sits under, and the comment at the end of its line.
	manifest.Note
}

// Lister is a Provider that can list what a target declares, item by item,
// for the inventory.
type Lister interface {
	Items(ctx context.Context, t config.Target) ([]Item, error)
}

// Entry is one item to declare: a kind such as brew, cask or runtime, a
// name, with @version for a runtime, and why it is there.
type Entry struct {
	Kind, Name, Why, Section string
}

// Adder is a Provider that can declare a new item in its manifest. It edits
// the manifest only; plan and apply install the item.
type Adder interface {
	Add(t config.Target, e Entry) error
}

// Remover is a Provider that can plan the uninstall of an item and the drop
// of its line from the manifest: a DELETE, the one change a plan only holds
// when a person asked for that item by name.
type Remover interface {
	PlanRemove(t config.Target, kind, name string) (plan.Action, error)
}

// Capturer is a Provider that can write its manifest from what the machine
// has, so a config can start from a machine that is already set up.
type Capturer interface {
	Capture(ctx context.Context, t config.Target) ([]byte, error)
}
