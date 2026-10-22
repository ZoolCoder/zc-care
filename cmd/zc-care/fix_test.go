package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"slices"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/security"
	"github.com/zoolcoder/zc-care/internal/sh"
)

func findings() []security.Result {
	return []security.Result{
		{Name: "firewall", Detail: "off", Fix: [][]string{{"sudo", "/usr/libexec/ApplicationFirewall/socketfilterfw", "--setglobalstate", "on"}}},
		{Name: "FileVault", Detail: "turn it on in System Settings"},
		{Name: "Gatekeeper", OK: true, Fix: [][]string{{"sudo", "spctl", "--master-enable"}}},
	}
}

func TestFixPlanHasOnlyFailedFixableChecksAndShowsTheExactCommand(t *testing.T) {
	p := fixPlan(findings(), &sh.Fake{})
	if len(p.Actions) != 1 {
		t.Fatalf("actions %+v: advice-only and passing checks must stay out", p.Actions)
	}
	a := p.Actions[0]
	if a.Resource != "firewall" || !a.Destructive ||
		a.Detail != "sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on" {
		t.Fatalf("action %+v", a)
	}
}

func TestFixNeedsAYesAndRunsTheListedCommands(t *testing.T) {
	r := &sh.Fake{}
	var out bytes.Buffer
	err := fixFindings(context.Background(), findings(), r, false, strings.NewReader(""), &out)
	if !errors.Is(err, errCancelled) || len(r.Ran) != 0 {
		t.Fatalf("ran without a yes: %v %v", err, r.Ran)
	}
	if !strings.Contains(out.String(), "sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on") {
		t.Fatalf("plan did not list the root command:\n%s", out.String())
	}
}

func TestFixRunsAfterAYesAndNothingFixableSaysSo(t *testing.T) {
	r := &sh.Fake{}
	var out bytes.Buffer
	// The re-check runs the real check commands against the fake, which
	// answers nothing, so some may still fail; the fix itself must have run.
	_ = fixFindings(context.Background(), findings(), r, true, strings.NewReader(""), &out)
	want := "sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on"
	if !slices.Contains(r.Ran, want) {
		t.Fatalf("ran %q, want %q", r.Ran, want)
	}

	out.Reset()
	r = &sh.Fake{}
	advice := []security.Result{{Name: "FileVault", Detail: "turn it on"}}
	if err := fixFindings(context.Background(), advice, r, true, strings.NewReader(""), &out); err != nil ||
		!strings.Contains(out.String(), "nothing doctor can fix") || len(r.Ran) != 0 {
		t.Fatalf("%v %q %v", err, out.String(), r.Ran)
	}
}

func TestDoctorFixRefusesJSON(t *testing.T) {
	if _, err := run(t, "", "doctor", "-fix", "-json"); err == nil {
		t.Fatal("-fix -json accepted")
	}
}

func TestADoctorFixIsNotJournaled(t *testing.T) {
	before, _ := loadJournal("", io.Discard)
	recordApply("", []engine.Outcome{{Target: "security", Resource: "firewall"}}, viaDoctor)
	if after, _ := loadJournal("", io.Discard); len(after) != len(before) {
		t.Fatalf("journaled %+v", after)
	}
}
