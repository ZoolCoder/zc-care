package packages

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"
	"sync"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/provider"
	"github.com/zoolcoder/zc-care/internal/sh"
)

// detail is what a package manager says about one installed package.
type detail struct {
	Version, App, Desc, Homepage string
}

// details maps "kind:name" (lower case), or "mas:ID", to what the manager
// knows about it.
type details map[string]detail

// Items lists every declared package with its state and, when the manager
// can say, its version, pending update and description. Packages installed
// on purpose that the manifest does not declare follow, as Extra.
func (p Provider) Items(ctx context.Context, t config.Target) ([]provider.Item, error) {
	// Details, updates and extras are extra: when brew cannot give them the
	// list still has what is declared. Each is a separate, slow-ish call, so
	// they run alongside the read.
	var (
		s      state
		err    error
		info   = details{}
		news   = updates{}
		chosen []item
		wg     sync.WaitGroup
	)
	wg.Go(func() { s, err = p.read(ctx, t) })
	wg.Go(func() {
		if d, err := brew.details(ctx, p.r); err == nil {
			info = d
		}
	})
	wg.Go(func() {
		if u, err := brew.outdated(ctx, p.r); err == nil {
			news = u
		}
	})
	wg.Go(func() { chosen, _ = brew.chosen(ctx, p.r) })
	wg.Wait()
	if err != nil {
		return nil, err
	}
	state := map[string]string{}
	for _, i := range s.missing {
		state[i.resource()] = provider.Missing
	}
	for _, i := range s.skipped {
		state[i.resource()] = provider.Skipped
	}
	for _, a := range s.manual {
		state[a.Resource] = provider.Manual
	}
	items := make([]provider.Item, 0, len(s.items)+len(s.unsupported))
	for _, i := range s.items {
		st, ok := state[i.resource()]
		if !ok {
			st = provider.InPlace
		}
		item := describe(i, st, info)
		item.Note = s.notes[i.resource()]
		if v, ok := lookup(news, i); ok && st == provider.InPlace {
			item.State, item.Latest = provider.Outdated, v.To
			if item.Version == "" {
				item.Version = v.From
			}
		}
		items = append(items, item)
	}
	for _, u := range s.unsupported {
		kind, name, _ := strings.Cut(u, ":")
		items = append(items, provider.Item{Name: name, Kind: kind, State: provider.Manual,
			Desc: "zc-care does not install this kind of entry"})
	}
	for _, i := range extras(chosen, s.items) {
		items = append(items, describe(i, provider.Extra, info))
	}
	return items, nil
}

func describe(i item, state string, info details) provider.Item {
	d, _ := lookup(info, i)
	return provider.Item{Name: i.Name, Kind: i.Kind, State: state,
		Version: d.Version, App: d.App, Desc: d.Desc, Homepage: d.Homepage}
}

// extras is what chosen holds that declared does not, compared as lookup
// compares: by App Store id, full name, or a tapped package's short name.
func extras(chosen, declared []item) []item {
	known := map[string]bool{}
	for _, i := range declared {
		if i.ID != "" {
			known[i.Kind+":"+i.ID] = true
		}
		key := strings.ToLower(i.Name)
		known[i.Kind+":"+key] = true
		known[i.Kind+":"+key[strings.LastIndex(key, "/")+1:]] = true
	}
	var out []item
	for _, i := range chosen {
		if _, ok := lookup(known, i); !ok {
			out = append(out, i)
		}
	}
	return out
}

// brewDetails reads every installed formula and cask in one call, then the
// App Store apps from mas.
func brewDetails(ctx context.Context, r sh.Runner) (details, error) {
	out, err := r.Output(ctx, "brew", "info", "--json=v2", "--installed")
	if err != nil {
		return nil, err
	}
	var doc struct {
		Formulae []struct {
			Name, Desc, Homepage string
			FullName             string `json:"full_name"`
			Installed            []struct{ Version string }
		}
		Casks []struct {
			Token, Desc, Homepage string
			FullToken             string `json:"full_token"`
			Name                  []string
			Installed             string
		}
	}
	if err := json.Unmarshal(out, &doc); err != nil {
		return nil, err
	}
	d := details{}
	for _, f := range doc.Formulae {
		v := detail{Desc: f.Desc, Homepage: f.Homepage}
		if n := len(f.Installed); n > 0 {
			v.Version = f.Installed[n-1].Version
		}
		d["brew:"+strings.ToLower(f.Name)] = v
		d["brew:"+strings.ToLower(f.FullName)] = v
	}
	for _, c := range doc.Casks {
		v := detail{Version: c.Installed, Desc: c.Desc, Homepage: c.Homepage}
		if len(c.Name) > 0 {
			v.App = c.Name[0]
		}
		d["cask:"+strings.ToLower(c.Token)] = v
		d["cask:"+strings.ToLower(c.FullToken)] = v
	}
	if r.Has("mas") {
		if out, err := r.Output(ctx, "mas", "list"); err == nil {
			for _, l := range lines(out) {
				if m := masLine.FindStringSubmatch(l); m != nil {
					d["mas:"+m[1]] = detail{App: m[2], Version: m[3]}
				}
			}
		}
	}
	return d, nil
}

// masLine is one line of `mas list`: id, name, (version).
var masLine = regexp.MustCompile(`^\s*(\d+)\s+(.*?)\s+\(([^)]*)\)\s*$`)
