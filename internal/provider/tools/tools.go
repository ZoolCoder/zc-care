// Package tools installs the language runtimes a mise config declares. mise
// resolves versions and installs; this provider asks it what is missing from
// one config file and turns each gap into a plan action.
package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
	"github.com/zoolcoder/zc-care/internal/sh"
)

type Provider struct{ r sh.Runner }

func New(r sh.Runner) Provider { return Provider{r: r} }

// version is one entry of `mise ls --json`.
type version struct {
	Version          string `json:"version"`
	RequestedVersion string `json:"requested_version"`
	Installed        bool   `json:"installed"`
	Source           struct {
		Path string `json:"path"`
	} `json:"source"`
}

// tool is one tool@version the config file asks for.
type tool struct{ name, version string }

func (t tool) String() string { return t.name + "@" + t.version }

// errManual is a gap a person must close before mise can be read.
type errManual struct{ resource, msg string }

func (e errManual) Error() string { return e.msg }

// installed is a declared tool's state: whether mise has it, and the version
// the request resolves to.
type installed struct {
	ok      bool
	version string
}

// declared lists the tools t's file asks for, and whether each is installed.
func (p Provider) declared(ctx context.Context, t config.Target) (map[tool]installed, error) {
	all, file, err := p.ls(ctx, t)
	if err != nil {
		return nil, err
	}
	return fromFile(all, file), nil
}

// ls is every tool version mise knows from t's directory, and t's file with
// symlinks resolved.
func (p Provider) ls(ctx context.Context, t config.Target) (map[string][]version, string, error) {
	if !p.r.Has("mise") {
		return nil, "", errManual{"mise", "mise is not on PATH; install mise first"}
	}
	file, err := filepath.EvalSymlinks(t.File)
	if err != nil {
		return nil, "", fmt.Errorf("read mise config: %w", err)
	}
	out, err := p.r.Output(ctx, "mise", "ls", "--json", "-C", filepath.Dir(t.File))
	if err != nil {
		if strings.Contains(err.Error(), "not trusted") {
			return nil, "", errManual{"trust", "mise does not trust " + t.File + "; review it, then run mise trust " + t.File}
		}
		return nil, "", err
	}
	var all map[string][]version
	if err := json.Unmarshal(out, &all); err != nil {
		return nil, "", fmt.Errorf("read mise ls output: %w", err)
	}
	return all, file, nil
}

// fromFile keeps the versions file asks for. mise also reports tools from
// global and parent configs, so only entries whose source is file count.
func fromFile(all map[string][]version, file string) map[tool]installed {
	tools := map[tool]installed{}
	for name, vs := range all {
		for _, v := range vs {
			if !sameFile(v.Source.Path, file) {
				continue
			}
			want := v.RequestedVersion
			if want == "" {
				want = v.Version
			}
			k := tool{name, want}
			if have := tools[k]; !have.ok {
				tools[k] = installed{ok: v.Installed, version: v.Version}
			}
		}
	}
	return tools
}

func sameFile(a, b string) bool {
	if a == "" {
		return false
	}
	if resolved, err := filepath.EvalSymlinks(a); err == nil {
		a = resolved
	}
	ai, err1 := os.Stat(a)
	bi, err2 := os.Stat(b)
	return err1 == nil && err2 == nil && os.SameFile(ai, bi)
}

// Plan installs each declared tool version that is missing.
func (p Provider) Plan(ctx context.Context, t config.Target) ([]plan.Action, error) {
	tools, err := p.declared(ctx, t)
	if m := (errManual{}); errors.As(err, &m) {
		return []plan.Action{{Op: plan.OpManual, Target: t.Name, Resource: m.resource, Detail: m.msg}}, nil
	}
	if err != nil {
		return nil, err
	}
	dir := filepath.Dir(t.File)
	var actions []plan.Action
	for _, k := range sorted(tools) {
		if tools[k].ok {
			continue
		}
		actions = append(actions, plan.Action{
			Op: plan.OpCreate, Target: t.Name, Resource: k.String(), Detail: "install with mise",
			Do: func(ctx context.Context) error { return p.r.Run(ctx, "mise", "install", "-C", dir, "--", k.String()) },
		})
	}
	if t.Upgrade {
		actions = append(actions, p.upgrades(ctx, t, tools)...)
	}
	return actions, nil
}

// upgrades is one UPDATE per installed tool with a newer version inside what
// the config requests.
func (p Provider) upgrades(ctx context.Context, t config.Target, tools map[tool]installed) []plan.Action {
	news, err := p.outdated(ctx, t)
	if err != nil {
		return []plan.Action{{Op: plan.OpManual, Target: t.Name, Resource: "upgrade", Detail: "cannot read updates: " + err.Error()}}
	}
	dir := filepath.Dir(t.File)
	var actions []plan.Action
	for _, k := range sorted(tools) {
		v, ok := news[k]
		if !ok || !tools[k].ok {
			continue
		}
		actions = append(actions, plan.Action{
			Op: plan.OpUpdate, Target: t.Name, Resource: k.String(),
			Detail: "upgrade with mise, " + v.current + " to " + v.latest,
			Do:     func(ctx context.Context) error { return p.r.Run(ctx, "mise", "upgrade", "-C", dir, "--", k.String()) },
		})
	}
	return actions
}

// newer is mise's view of one outdated tool.
type newer struct{ current, latest string }

// outdated reads `mise outdated --json`: a map from tool to one entry, or to
// a list when several versions of the tool are requested.
func (p Provider) outdated(ctx context.Context, t config.Target) (map[tool]newer, error) {
	out, err := p.r.Output(ctx, "mise", "outdated", "--json", "-C", filepath.Dir(t.File))
	if err != nil {
		return nil, err
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil, fmt.Errorf("read mise outdated output: %w", err)
	}
	type entry struct{ Name, Requested, Current, Latest string }
	news := map[tool]newer{}
	for key, msg := range raw {
		var list []entry
		if err := json.Unmarshal(msg, &list); err != nil {
			var one entry
			if err := json.Unmarshal(msg, &one); err != nil {
				return nil, fmt.Errorf("read mise outdated output: %w", err)
			}
			list = []entry{one}
		}
		for _, e := range list {
			name := e.Name
			if name == "" {
				name, _, _ = strings.Cut(key, "@")
			}
			if e.Latest != "" && e.Latest != e.Current {
				news[tool{name, e.Requested}] = newer{e.Current, e.Latest}
			}
		}
	}
	return news, nil
}

// Measure counts the declared tool versions that are installed.
func (p Provider) Measure(ctx context.Context, t config.Target) (provider.Live, error) {
	tools, err := p.declared(ctx, t)
	if err != nil {
		return provider.Live{}, err
	}
	live := provider.Live{Declared: len(tools)}
	for _, have := range tools {
		if have.ok {
			live.InPlace++
		}
	}
	live.Summary = fmt.Sprintf("%d of %d tools installed", live.InPlace, live.Declared)
	return live, nil
}

func (p Provider) Status(ctx context.Context, t config.Target) (string, error) {
	live, err := p.Measure(ctx, t)
	return live.Summary, err
}

func sorted(m map[tool]installed) []tool {
	keys := make([]tool, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i].String() < keys[j].String() })
	return keys
}

// Items lists every declared tool version, with the version it resolves to
// and any newer one. Installed versions the file does not ask for follow, as
// Extra.
func (p Provider) Items(ctx context.Context, t config.Target) ([]provider.Item, error) {
	all, file, err := p.ls(ctx, t)
	if err != nil {
		return nil, err
	}
	tools := fromFile(all, file)
	// Updates are extra: without them the inventory still lists everything.
	news, _ := p.outdated(ctx, t)
	data, _ := os.ReadFile(file)
	notes := declaredTools(data)
	items := make([]provider.Item, 0, len(tools))
	have := map[string]bool{}
	for _, k := range sorted(tools) {
		have[k.name+"@"+tools[k].version] = true
		item := provider.Item{Name: k.name, Kind: "runtime", State: provider.Missing,
			Version: tools[k].version, Desc: "requested " + k.version, Note: notes[k.name]}
		if tools[k].ok {
			item.State = provider.InPlace
			if v, ok := news[k]; ok {
				item.State, item.Latest = provider.Outdated, v.latest
			}
		}
		items = append(items, item)
	}
	for _, name := range names(all) {
		for _, v := range all[name] {
			if !v.Installed || have[name+"@"+v.Version] {
				continue
			}
			have[name+"@"+v.Version] = true
			item := provider.Item{Name: name, Kind: "runtime", State: provider.Extra, Version: v.Version,
				Desc: "installed, no config asks for it"}
			if v.Source.Path != "" {
				item.Desc = "declared in " + v.Source.Path
			}
			items = append(items, item)
		}
	}
	return items, nil
}

// Capture writes a mise config pinning every installed tool version, as the
// configs that asked for it requested it.
func (p Provider) Capture(ctx context.Context, t config.Target) ([]byte, error) {
	all, _, err := p.ls(ctx, t)
	if err != nil {
		return nil, err
	}
	var b strings.Builder
	b.WriteString("# Captured by zc-care from what mise has installed.\n[tools]\n")
	for _, name := range names(all) {
		var want []string
		for _, v := range all[name] {
			w := v.RequestedVersion
			if w == "" {
				w = v.Version
			}
			if v.Installed && !slices.Contains(want, strconv.Quote(w)) {
				want = append(want, strconv.Quote(w))
			}
		}
		switch len(want) {
		case 0:
		case 1:
			fmt.Fprintf(&b, "%s = %s\n", name, want[0])
		default:
			fmt.Fprintf(&b, "%s = [%s]\n", name, strings.Join(want, ", "))
		}
	}
	return []byte(b.String()), nil
}

func names(all map[string][]version) []string {
	out := make([]string, 0, len(all))
	for name := range all {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

func (Provider) Programs(config.Target) []string { return []string{"mise"} }
