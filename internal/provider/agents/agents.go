// Package agents declares, once, what every AI coding agent on the machine
// gets: MCP servers, a rules file, skills, and the local models Ollama serves.
// It writes them into the configs of Claude Code, Codex, Cursor and Gemini CLI.
//
// It only adds and updates. A server, skill or model the manifest does not
// name is left alone, so the provider never plans a deletion.
package agents

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
	"github.com/zoolcoder/zc-care/internal/sh"
)

// Manifest is the agents file a target names.
type Manifest struct {
	// Clients are the agents to write to; empty means every client.
	Clients []string          `yaml:"clients"`
	Servers map[string]Server `yaml:"servers"`
	// Rules is a Markdown file every client reads as standing instructions.
	Rules string `yaml:"rules"`
	// Skills are folders, each holding a SKILL.md.
	Skills []string `yaml:"skills"`
	// Models are Ollama models, such as qwen3:8b.
	Models []string `yaml:"models"`
}

// Server is one MCP server: a command to start, or a URL to reach.
type Server struct {
	Command string            `yaml:"command"`
	Args    []string          `yaml:"args"`
	Env     map[string]string `yaml:"env"`
	URL     string            `yaml:"url"`
	Headers map[string]string `yaml:"headers"`
}

type Provider struct {
	r    sh.Runner
	home string
}

func New(r sh.Runner) Provider {
	home, _ := os.UserHomeDir()
	return Provider{r: r, home: home}
}

// Load reads and checks the manifest; relative rules and skill paths resolve
// against its folder.
func Load(path string) (Manifest, error) {
	var m Manifest
	b, err := os.ReadFile(path)
	if err != nil {
		return m, fmt.Errorf("read agents manifest: %w", err)
	}
	dec := yaml.NewDecoder(bytes.NewReader(b))
	dec.KnownFields(true)
	if err := dec.Decode(&m); err != nil && !errors.Is(err, io.EOF) {
		return m, fmt.Errorf("%s: %w", path, err)
	}
	var errs []error
	for _, c := range m.Clients {
		if _, ok := clients[c]; !ok {
			errs = append(errs, fmt.Errorf("%s: client %q is not one of %s", path, c, strings.Join(sortedKeys(clients), ", ")))
		}
	}
	for name, s := range m.Servers {
		if (s.Command == "") == (s.URL == "") {
			errs = append(errs, fmt.Errorf("%s: server %s needs a command or a url, not both", path, name))
		}
	}
	if len(m.Clients) == 0 {
		m.Clients = sortedKeys(clients)
	}
	dir := filepath.Dir(path)
	abs := func(p string) string {
		if p == "" || filepath.IsAbs(p) {
			return p
		}
		return filepath.Join(dir, p)
	}
	m.Rules = abs(m.Rules)
	for i, s := range m.Skills {
		m.Skills[i] = abs(s)
	}
	return m, errors.Join(errs...)
}

// change is one declared thing and what it takes to put it in place.
type change struct {
	item   provider.Item
	action plan.Action // zero when in place
}

// changes reads every declared thing's live state.
func (p Provider) changes(ctx context.Context, t config.Target) ([]change, error) {
	m, err := Load(t.File)
	if err != nil {
		return nil, err
	}
	var out []change
	for _, name := range m.Clients {
		c := clients[name]
		for _, s := range sortedKeys(m.Servers) {
			ch, err := p.server(t.Name, name, c, s, m.Servers[s])
			if err != nil {
				return nil, err
			}
			out = append(out, ch)
		}
		// A client with no rules file or skills folder is skipped: there is
		// nothing to keep in place.
		if m.Rules != "" && c.rules != "" {
			ch, err := p.rules(t.Name, name, c, m.Rules)
			if err != nil {
				return nil, err
			}
			out = append(out, ch)
		}
		for _, dir := range m.Skills {
			if c.skills == "" {
				continue
			}
			ch, err := p.skill(t.Name, name, c, dir)
			if err != nil {
				return nil, err
			}
			out = append(out, ch)
		}
	}
	models, err := p.models(ctx, t.Name, m.Models)
	return append(out, models...), err
}

// Plan lists what is not in place yet.
func (p Provider) Plan(ctx context.Context, t config.Target) ([]plan.Action, error) {
	all, err := p.changes(ctx, t)
	var actions []plan.Action
	for _, c := range all {
		if c.action.Op != "" {
			actions = append(actions, c.action)
		}
	}
	return actions, err
}

// Items lists every server, rules file, skill and model per client.
func (p Provider) Items(ctx context.Context, t config.Target) ([]provider.Item, error) {
	all, err := p.changes(ctx, t)
	items := make([]provider.Item, 0, len(all))
	for _, c := range all {
		items = append(items, c.item)
	}
	return items, err
}

func (p Provider) Measure(ctx context.Context, t config.Target) (provider.Live, error) {
	items, err := p.Items(ctx, t)
	if err != nil {
		return provider.Live{}, err
	}
	m := provider.Live{Declared: len(items)}
	for _, it := range items {
		if it.State == provider.InPlace {
			m.InPlace++
		}
	}
	m.Summary = fmt.Sprintf("%d of %d agent settings in place", m.InPlace, m.Declared)
	return m, nil
}

func (p Provider) Status(ctx context.Context, t config.Target) (string, error) {
	m, err := p.Measure(ctx, t)
	return m.Summary, err
}

// Programs lists ollama when the manifest asks for models.
func (p Provider) Programs(t config.Target) []string {
	if m, err := Load(t.File); err == nil && len(m.Models) > 0 {
		return []string{"ollama"}
	}
	return nil
}

func item(name, kind, app, state string) provider.Item {
	return provider.Item{Name: name, Kind: kind, App: app, State: state}
}

// rules keeps the rules file's text in a marked block of the client's own
// rules file, so what the user wrote around it stays theirs.
func (p Provider) rules(target, client string, c client, src string) (change, error) {
	want, err := os.ReadFile(src)
	if err != nil {
		return change{}, fmt.Errorf("read rules: %w", err)
	}
	path := filepath.Join(p.home, c.rules)
	have, _ := os.ReadFile(path)
	next := withBlock(string(have), "<!-- zc-care agents: begin -->", "<!-- zc-care agents: end -->", string(want))
	ch := change{item: item("rules", "rules", client, provider.InPlace)}
	if next == string(have) {
		return ch, nil
	}
	ch.item.State, ch.action = provider.Missing, plan.Action{Op: plan.OpUpdate, Target: target,
		Resource: "rules (" + client + ")", Detail: "write " + filepath.Base(src) + " into ~/" + c.rules,
		Do: func(context.Context) error { return writeFile(path, []byte(next)) }}
	if len(have) == 0 {
		ch.action.Op = plan.OpCreate
	}
	return ch, nil
}

// skill copies a skill folder into the client's skills folder.
func (p Provider) skill(target, client string, c client, src string) (change, error) {
	name := filepath.Base(src)
	resource := "skill " + name + " (" + client + ")"
	want, err := tree(src)
	if err != nil {
		return change{}, fmt.Errorf("read skill %s: %w", name, err)
	}
	dst := filepath.Join(p.home, c.skills, name)
	have, _ := tree(dst)
	var stale []string
	for f, b := range want {
		if !bytes.Equal(have[f], b) {
			stale = append(stale, f)
		}
	}
	ch := change{item: item(name, "skill", client, provider.InPlace)}
	if len(stale) == 0 {
		return ch, nil
	}
	slices.Sort(stale)
	op, state := plan.OpUpdate, provider.Differs
	if len(have) == 0 {
		op, state = plan.OpCreate, provider.Missing
	}
	ch.item.State, ch.action = state, plan.Action{Op: op, Target: target, Resource: resource,
		Detail: fmt.Sprintf("copy %d file(s) to ~/%s", len(stale), filepath.Join(c.skills, name)),
		Do: func(context.Context) error {
			for _, f := range stale {
				if err := writeFile(filepath.Join(dst, f), want[f]); err != nil {
					return err
				}
			}
			return nil
		}}
	return ch, nil
}

// models pulls the Ollama models that are not on this machine.
func (p Provider) models(ctx context.Context, target string, models []string) ([]change, error) {
	if len(models) == 0 {
		return nil, nil
	}
	if !p.r.Has("ollama") {
		return []change{{item: item("ollama", "model", "ollama", provider.Manual), action: plan.Action{
			Op: plan.OpManual, Target: target, Resource: "ollama", Detail: "install Ollama to pull the models"}}}, nil
	}
	out, err := p.r.Output(ctx, "ollama", "list")
	if err != nil {
		return nil, fmt.Errorf("read ollama models (is ollama serve running?): %w", err)
	}
	have := map[string]bool{}
	for line := range strings.Lines(string(out)) {
		if f := strings.Fields(line); len(f) > 0 && f[0] != "NAME" {
			have[f[0]] = true
		}
	}
	var changes []change
	for _, m := range models {
		ch := change{item: item(m, "model", "ollama", provider.InPlace)}
		if !have[m] && !have[m+":latest"] {
			ch.item.State, ch.action = provider.Missing, plan.Action{Op: plan.OpCreate, Target: target,
				Resource: "model " + m, Detail: "ollama pull " + m,
				Do: func(ctx context.Context) error { return p.r.Run(ctx, "ollama", "pull", "--", m) }}
		}
		changes = append(changes, ch)
	}
	return changes, nil
}

// withBlock puts body between the begin and end markers in text, replacing
// the block there or adding one at the end.
func withBlock(text, begin, end, body string) string {
	block := begin + "\n" + strings.TrimRight(body, "\n") + "\n" + end + "\n"
	if i := strings.Index(text, begin); i >= 0 {
		if j := strings.Index(text[i:], end); j >= 0 {
			rest := strings.TrimPrefix(text[i+j+len(end):], "\n")
			return text[:i] + block + rest
		}
	}
	if text != "" && !strings.HasSuffix(text, "\n\n") {
		text = strings.TrimRight(text, "\n") + "\n\n"
	}
	return text + block
}

// tree reads every regular file under dir, by slash path.
func tree(dir string) (map[string][]byte, error) {
	files := map[string][]byte{}
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || !d.Type().IsRegular() {
			return err
		}
		rel, _ := filepath.Rel(dir, path)
		files[filepath.ToSlash(rel)], err = os.ReadFile(path)
		return err
	})
	return files, err
}

// writeFile replaces path in one rename, so an agent that reads the file at
// the same moment sees the old or the new content, never half.
func writeFile(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	mode := os.FileMode(0o600)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := tmp.Write(b); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), mode); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// jsonEqual compares two JSON values whatever their key order.
func jsonEqual(a, b []byte) bool {
	var x, y any
	return json.Unmarshal(a, &x) == nil && json.Unmarshal(b, &y) == nil && reflect.DeepEqual(x, y)
}

func sortedKeys[V any](m map[string]V) []string {
	return slices.Sorted(maps.Keys(m))
}
