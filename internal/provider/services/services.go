// Package services keeps background services running: Homebrew services and
// launchd agents from plists. It starts what is stopped and never stops
// anything.
package services

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
	"github.com/zoolcoder/zc-care/internal/sh"
)

// running are the brew services states that count as in place: a service
// that runs on a schedule, such as asimov, is scheduled between runs.
var running = []string{"started", "scheduled"}

type Provider struct {
	r   sh.Runner
	uid int
}

func New(r sh.Runner) Provider { return Provider{r: r, uid: os.Getuid()} }

// service is one declared service or agent with what the machine says.
type service struct {
	kind, name string
	// file is an agent's plist.
	file   string
	state  string
	detail string
}

// Label is the agent's launchd label, which by convention is its file name.
func Label(plist string) string { return strings.TrimSuffix(filepath.Base(plist), ".plist") }

func (p Provider) domain() string { return fmt.Sprintf("gui/%d", p.uid) }

// read asks launchctl about the agents while brew lists its services, the
// slow part.
func (p Provider) read(ctx context.Context, t config.Target) ([]service, error) {
	agents := make([]service, len(t.Agents))
	var wg sync.WaitGroup
	for i, plist := range t.Agents {
		wg.Go(func() {
			s := service{kind: "agent", name: Label(plist), file: plist, state: provider.Missing, detail: "not loaded"}
			if _, err := p.r.Output(ctx, "launchctl", "print", p.domain()+"/"+s.name); err == nil {
				s.state, s.detail = provider.InPlace, "loaded"
			}
			agents[i] = s
		})
	}
	defer wg.Wait()
	var out []service
	if len(t.Services) > 0 {
		status, err := p.brewStatus(ctx)
		if err != nil {
			return nil, err
		}
		for _, name := range t.Services {
			s := service{kind: "brew", name: name, state: provider.Missing, detail: "not installed"}
			if st, ok := status[name]; ok {
				s.detail = st
				if slices.Contains(running, st) {
					s.state = provider.InPlace
				}
			}
			out = append(out, s)
		}
	}
	wg.Wait()
	return append(out, agents...), nil
}

// brewStatus maps each Homebrew service to its state, such as started.
func (p Provider) brewStatus(ctx context.Context) (map[string]string, error) {
	out, err := p.r.Output(ctx, "brew", "services", "list", "--json")
	if err != nil {
		return nil, fmt.Errorf("brew services list: %w", err)
	}
	var list []struct{ Name, Status string }
	if err := json.Unmarshal(out, &list); err != nil {
		return nil, fmt.Errorf("brew services list: %w", err)
	}
	status := make(map[string]string, len(list))
	for _, s := range list {
		status[s.Name] = s.Status
	}
	return status, nil
}

// Plan starts each service that is not running and loads each agent that is
// not loaded. An agent's file may not exist yet: a dotfiles target
// earlier in the same apply writes it.
func (p Provider) Plan(ctx context.Context, t config.Target) ([]plan.Action, error) {
	services, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	var actions []plan.Action
	for _, s := range services {
		if s.state == provider.InPlace {
			continue
		}
		a := plan.Action{Op: plan.OpCreate, Target: t.Name, Resource: s.kind + ":" + s.name}
		switch s.kind {
		case "brew":
			a.Detail = "start with brew services, and at every login (now " + s.detail + ")"
			// restart also recovers a service that started and then failed.
			a.Do = func(ctx context.Context) error { return p.r.Run(ctx, "brew", "services", "restart", s.name) }
		default:
			a.Detail = "load " + filepath.Base(s.file) + " into launchd"
			a.Do = func(ctx context.Context) error { return p.r.Run(ctx, "launchctl", "bootstrap", p.domain(), s.file) }
		}
		actions = append(actions, a)
	}
	return actions, nil
}

func (p Provider) Measure(ctx context.Context, t config.Target) (provider.Live, error) {
	services, err := p.read(ctx, t)
	if err != nil {
		return provider.Live{}, err
	}
	live := provider.Live{Declared: len(services)}
	for _, s := range services {
		if s.state == provider.InPlace {
			live.InPlace++
		}
	}
	live.Summary = fmt.Sprintf("%d of %d services running", live.InPlace, live.Declared)
	return live, nil
}

func (p Provider) Status(ctx context.Context, t config.Target) (string, error) {
	live, err := p.Measure(ctx, t)
	return live.Summary, err
}

// Items is each service, then each agent, as declared.
func (p Provider) Items(ctx context.Context, t config.Target) ([]provider.Item, error) {
	services, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	items := make([]provider.Item, 0, len(services))
	for _, s := range services {
		items = append(items, provider.Item{Name: s.name, Kind: s.kind, State: s.state, Desc: s.detail})
	}
	return items, nil
}

func (Provider) Programs(t config.Target) []string {
	var progs []string
	if len(t.Services) > 0 {
		progs = append(progs, "brew")
	}
	if len(t.Agents) > 0 {
		progs = append(progs, "launchctl")
	}
	return progs
}
