package settings

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
	"github.com/zoolcoder/zc-care/internal/sh"
)

func target() config.Target {
	return config.Target{Name: "macos", Provider: "settings", Defaults: map[string]map[string]any{
		"NSGlobalDomain":          {"KeyRepeat": 2, "NSWindowResizeTime": 0.001, "ApplePressAndHoldEnabled": false},
		"com.apple.dock":          {"autohide": true},
		"com.apple.screencapture": {"location": "~/Screenshots"},
	}}
}

func read(domain, key string) string { return sh.Line("defaults", "read", domain, key) }

func readType(domain, key string) string { return sh.Line("defaults", "read-type", domain, key) }

// notSet is what defaults says for a key that has no value.
func notSet(domain, key string) error {
	return fmt.Errorf("%s: exit status 1: The domain/default pair of (%s, %s) does not exist", read(domain, key), domain, key)
}

// machine has KeyRepeat and the resize time as declared, the press-and-hold
// popup on, and neither the Dock nor the screenshot key set.
func machine() *sh.Fake {
	return &sh.Fake{
		Out: map[string]string{
			read("NSGlobalDomain", "KeyRepeat"):                    "2\n",
			readType("NSGlobalDomain", "KeyRepeat"):                "Type is integer\n",
			read("NSGlobalDomain", "NSWindowResizeTime"):           "0.0010\n",
			readType("NSGlobalDomain", "NSWindowResizeTime"):       "Type is float\n",
			read("NSGlobalDomain", "ApplePressAndHoldEnabled"):     "1\n",
			readType("NSGlobalDomain", "ApplePressAndHoldEnabled"): "Type is boolean\n",
		},
		Err: map[string]error{
			read("com.apple.dock", "autohide"):          notSet("com.apple.dock", "autohide"),
			read("com.apple.screencapture", "location"): notSet("com.apple.screencapture", "location"),
		},
	}
}

func TestReadSurfacesErrorsOtherThanNotSet(t *testing.T) {
	r := machine()
	r.Err[read("NSGlobalDomain", "KeyRepeat")] = errors.New("signal: killed")
	p := Provider{r: r, home: "/Users/me"}
	if _, err := p.Plan(context.Background(), target()); err == nil || !strings.Contains(err.Error(), "killed") {
		t.Fatalf("plan %v", err)
	}
	if _, err := p.Measure(context.Background(), target()); err == nil {
		t.Fatal("measure hid the error")
	}
}

func TestWrongTypeIsFixed(t *testing.T) {
	r := machine()
	r.Out[readType("NSGlobalDomain", "KeyRepeat")] = "Type is string\n"
	p := Provider{r: r, home: "/Users/me"}
	actions, err := p.Plan(context.Background(), target())
	if err != nil || !slices.ContainsFunc(actions, func(a plan.Action) bool {
		return a.Op == plan.OpUpdate && a.Resource == "NSGlobalDomain KeyRepeat"
	}) {
		t.Fatalf("plan %v %v", actions, err)
	}
}

func TestPlanWritesWhatDiffersAndRestartsReaders(t *testing.T) {
	r := machine()
	p := Provider{r: r, home: "/Users/me"}
	actions, err := p.Plan(context.Background(), target())
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, a := range actions {
		got = append(got, string(a.Op)+" "+a.Resource)
		if err := a.Do(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	want := []string{
		string(plan.OpUpdate) + " NSGlobalDomain ApplePressAndHoldEnabled",
		string(plan.OpCreate) + " com.apple.dock autohide",
		string(plan.OpCreate) + " com.apple.screencapture location",
		string(plan.OpUpdate) + " restart Dock",
		string(plan.OpUpdate) + " restart SystemUIServer",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("plan\n got %q\nwant %q", got, want)
	}
	ran := []string{
		"defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false",
		"defaults write com.apple.dock autohide -bool true",
		"defaults write com.apple.screencapture location -string /Users/me/Screenshots",
		"killall Dock",
		"killall SystemUIServer",
	}
	if !slices.Equal(r.Ran, ran) {
		t.Fatalf("ran\n got %q\nwant %q", r.Ran, ran)
	}
}

func TestMeasureCountsKeysInPlace(t *testing.T) {
	p := Provider{r: machine(), home: "/Users/me"}
	live, err := p.Measure(context.Background(), target())
	if err != nil {
		t.Fatal(err)
	}
	if live.InPlace != 2 || live.Declared != 5 {
		t.Fatalf("live %+v", live)
	}
	items, _ := p.Items(context.Background(), target())
	if items[0].Name != "NSGlobalDomain ApplePressAndHoldEnabled" || items[0].State != provider.Differs || items[0].Version != "1" {
		t.Fatalf("first item %+v", items[0])
	}
}

func TestSame(t *testing.T) {
	for _, c := range []struct {
		want      any
		have, typ string
		same      bool
	}{
		{true, "1", "Type is boolean", true}, {false, "0", "Type is boolean", true}, {true, "0", "Type is boolean", false}, {false, "", "Type is boolean", false},
		{true, "1", "Type is string", false}, {1, "1", "Type is boolean", false},
		{15, "15", "Type is integer", true}, {15, "15.0", "Type is integer", false},
		{0.15, "0.15000", "Type is float", true}, {0.15, "0.1500000059604645", "Type is float", true}, {0.15, "0.16", "Type is float", false}, {0.0, "0", "Type is float", true},
		{0.0, "0", "Type is integer", false},
		{"Nlsv", "Nlsv", "Type is string", true}, {"Nlsv", "icnv", "Type is string", false}, {"1", "1", "Type is integer", false},
	} {
		if got := same(c.want, c.have, c.typ); got != c.same {
			t.Errorf("same(%v, %q, %q) = %v", c.want, c.have, c.typ, got)
		}
	}
}
