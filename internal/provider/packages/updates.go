package packages

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"

	"github.com/zoolcoder/zc-care/internal/sh"
)

// update is a newer version an installed package can move to.
type update struct{ From, To string }

// updates maps "kind:name" (lower case), or "mas:ID", to its update.
type updates map[string]update

// lookup finds i in a map keyed like details and updates: by full name or
// App Store id, then by a tapped package's short name.
func lookup[V any](m map[string]V, i item) (V, bool) {
	key := strings.ToLower(i.Name)
	if i.ID != "" {
		key = i.ID
	}
	if v, ok := m[i.Kind+":"+key]; ok {
		return v, true
	}
	v, ok := m[i.Kind+":"+key[strings.LastIndex(key, "/")+1:]]
	return v, ok
}

// brewChosen lists what a person installed on purpose: taps beyond
// Homebrew's own, formulae installed on request that nothing depends on,
// casks, and App Store apps.
func brewChosen(ctx context.Context, r sh.Runner) ([]item, error) {
	queries := []struct {
		kind string
		args []string
	}{
		{"tap", []string{"tap"}},
		{"brew", []string{"leaves", "--installed-on-request"}},
		{"cask", []string{"list", "--cask", "-1", "--full-name"}},
	}
	// Each query starts Ruby, so they run side by side.
	results := make([][]byte, len(queries))
	errs := make([]error, len(queries))
	var wg sync.WaitGroup
	for n, q := range queries {
		wg.Go(func() { results[n], errs[n] = r.Output(ctx, "brew", q.args...) })
	}
	wg.Wait()
	if err := errors.Join(errs...); err != nil {
		return nil, err
	}
	var out []item
	for n, q := range queries {
		for _, name := range lines(results[n]) {
			if name == "" || q.kind == "tap" && strings.HasPrefix(name, "homebrew/") {
				continue
			}
			out = append(out, item{Kind: q.kind, Name: name})
		}
	}
	if r.Has("mas") {
		b, err := r.Output(ctx, "mas", "list")
		if err != nil {
			return nil, err
		}
		for _, l := range lines(b) {
			if m := masLine.FindStringSubmatch(l); m != nil {
				out = append(out, item{Kind: "mas", Name: m[2], ID: m[1]})
			}
		}
	}
	return out, nil
}

// brewOutdated reads Homebrew's and the App Store's pending updates. Pinned
// formulae are left out: a pin says do not upgrade.
func brewOutdated(ctx context.Context, r sh.Runner) (updates, error) {
	b, err := r.Output(ctx, "brew", "outdated", "--json=v2")
	if err != nil {
		return nil, err
	}
	type pkg struct {
		Name      string
		Installed []string `json:"installed_versions"`
		Current   string   `json:"current_version"`
		Pinned    bool
	}
	var doc struct{ Formulae, Casks []pkg }
	if err := json.Unmarshal(b, &doc); err != nil {
		return nil, fmt.Errorf("read brew outdated: %w", err)
	}
	u := updates{}
	for kind, pkgs := range map[string][]pkg{"brew": doc.Formulae, "cask": doc.Casks} {
		for _, p := range pkgs {
			if p.Pinned {
				continue
			}
			v := update{To: p.Current}
			if n := len(p.Installed); n > 0 {
				v.From = p.Installed[n-1]
			}
			u[kind+":"+strings.ToLower(p.Name)] = v
		}
	}
	if r.Has("mas") {
		if b, err := r.Output(ctx, "mas", "outdated"); err == nil {
			for _, l := range lines(b) {
				if m := masOutdated.FindStringSubmatch(l); m != nil {
					u["mas:"+m[1]] = update{From: m[2], To: m[3]}
				}
			}
		}
	}
	return u, nil
}

// masOutdated is one line of `mas outdated`: id, name, (old -> new).
var masOutdated = regexp.MustCompile(`^\s*(\d+)\s+.*\((\S+)\s+->\s+(\S+)\)\s*$`)

func brewUpgrade(r sh.Runner, i item) func(context.Context) error {
	switch i.Kind {
	case "cask":
		return run(r, "brew", "upgrade", "--cask", "--", i.Name)
	case "mas":
		return run(r, "mas", "upgrade", i.ID)
	}
	return run(r, "brew", "upgrade", "--", i.Name)
}
