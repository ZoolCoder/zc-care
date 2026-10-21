package services

import (
	"context"
	"slices"
	"testing"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/sh"
)

const list = `[{"name":"sketchybar","status":"started"},{"name":"asimov","status":"scheduled"},
{"name":"colima","status":"none"},{"name":"borders","status":"error"}]`

func target() config.Target {
	return config.Target{Name: "services", Provider: "services",
		Services: []string{"sketchybar", "asimov", "colima", "borders", "postgresql"},
		Agents:   []string{"/Users/me/Library/LaunchAgents/local.weekly.plist", "/Users/me/Library/LaunchAgents/local.ssh.plist"}}
}

// machine runs sketchybar and asimov, has colima stopped, borders failed and
// postgresql not installed, and has only the ssh agent loaded.
func machine() *sh.Fake {
	return &sh.Fake{
		Out: map[string]string{
			"brew services list --json":         list,
			"launchctl print gui/501/local.ssh": "state = running\n",
		},
	}
}

func TestPlanStartsWhatIsNotRunning(t *testing.T) {
	r := machine()
	p := Provider{r: r, uid: 501}
	actions, err := p.Plan(context.Background(), target())
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, a := range actions {
		got = append(got, a.Resource)
		if err := a.Do(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if want := []string{"brew:colima", "brew:borders", "brew:postgresql", "agent:local.weekly"}; !slices.Equal(got, want) {
		t.Fatalf("plan\n got %q\nwant %q", got, want)
	}
	ran := []string{
		"brew services restart -- colima", "brew services restart -- borders", "brew services restart -- postgresql",
		"launchctl enable gui/501/local.weekly", "launchctl bootstrap gui/501 /Users/me/Library/LaunchAgents/local.weekly.plist",
	}
	if !slices.Equal(r.Ran, ran) {
		t.Fatalf("ran\n got %q\nwant %q", r.Ran, ran)
	}
}

func TestMeasureAndPrograms(t *testing.T) {
	p := Provider{r: machine(), uid: 501}
	live, err := p.Measure(context.Background(), target())
	if err != nil {
		t.Fatal(err)
	}
	if live.InPlace != 3 || live.Declared != 7 {
		t.Fatalf("live %+v", live)
	}
	if got := p.Programs(config.Target{Agents: []string{"a.plist"}}); !slices.Equal(got, []string{"launchctl"}) {
		t.Fatalf("programs %v", got)
	}
}

func TestPlanNeedsNoBrewForAgentsOnly(t *testing.T) {
	p := Provider{r: &sh.Fake{}, uid: 501}
	tg := target()
	tg.Services = nil
	if _, err := p.Plan(context.Background(), tg); err != nil {
		t.Fatal(err)
	}
}
