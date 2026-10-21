package agents

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/sh"
)

const secret = "s3cr3t-value"

// withSecrets points the setup's manifest at servers that use keychain refs.
func withSecrets(t *testing.T) (Provider, config.Target, string, *sh.Fake) {
	t.Helper()
	p, target, home, f := setup(t)
	write(t, target.File, `
clients: [claude]
servers:
  docs:
    command: npx
    env: {DOCS_TOKEN: "${keychain:docs-token}"}
  remote:
    url: https://mcp.example.com/mcp
    headers: {Authorization: "Bearer ${keychain:api/me}"}
`)
	f.Out["security find-generic-password -s docs-token -w"] = secret + "\n"
	f.Out["security find-generic-password -s api -a me -w"] = secret + "\n"
	return p, target, home, f
}

func TestKeychainRefsAreResolvedOnWriteAndNeverInThePlan(t *testing.T) {
	p, target, home, _ := withSecrets(t)
	ctx := context.Background()
	actions, err := p.Plan(ctx, target)
	if err != nil || len(actions) != 2 {
		t.Fatalf("plan %v: %v", actions, err)
	}
	for _, a := range actions {
		if strings.Contains(fmt.Sprintf("%+v", a), secret) {
			t.Errorf("plan shows the secret: %+v", a)
		}
	}
	apply(t, actions)
	claude := read(t, filepath.Join(home, ".claude.json"))
	for _, want := range []string{`"DOCS_TOKEN": "` + secret + `"`, `"Authorization": "Bearer ` + secret + `"`} {
		if !strings.Contains(claude, want) {
			t.Errorf(".claude.json lacks %s:\n%s", want, claude)
		}
	}
	// The live file holds the secret and the manifest the ref: no drift.
	if actions, err := p.Plan(ctx, target); err != nil || len(actions) != 0 {
		t.Fatalf("second plan %v: %v", actions, err)
	}
	items, _ := p.Items(ctx, target)
	for _, it := range items {
		if strings.Contains(fmt.Sprintf("%+v", it), secret) {
			t.Errorf("item shows the secret: %+v", it)
		}
	}
}

func TestChangedSecretIsAnUpdate(t *testing.T) {
	p, target, _, f := withSecrets(t)
	ctx := context.Background()
	actions, _ := p.Plan(ctx, target)
	apply(t, actions)
	f.Out["security find-generic-password -s docs-token -w"] = "rotated\n"
	actions, err := p.Plan(ctx, target)
	if err != nil || len(actions) != 1 || !strings.HasPrefix(actions[0].Resource, "docs") {
		t.Fatalf("plan %+v: %v", actions, err)
	}
}

func TestMissingSecretNamesTheRefAndHowToAddIt(t *testing.T) {
	p, target, _, f := withSecrets(t)
	f.Err = map[string]error{"security find-generic-password -s api -a me -w": errors.New("could not be found")}
	_, err := p.Plan(context.Background(), target)
	if err == nil {
		t.Fatal("no error")
	}
	for _, want := range []string{"${keychain:api/me}", "security add-generic-password -s api -a me -w", "server remote"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error lacks %q: %v", want, err)
		}
	}
	if strings.Contains(err.Error(), secret) {
		t.Errorf("error shows the secret: %v", err)
	}
}

func TestMalformedRefIsRefusedByLoad(t *testing.T) {
	dir := t.TempDir()
	for _, bad := range []string{"${keychain:}", "${keychain:/me}", "${keychain:svc/}", "${keychain:svc", "${keychain:a b}"} {
		write(t, filepath.Join(dir, "a.yaml"), "servers:\n  x:\n    command: a\n    env: {T: \""+bad+"\"}\n")
		_, err := Load(filepath.Join(dir, "a.yaml"))
		if err == nil || !strings.Contains(err.Error(), "malformed secret reference") {
			t.Errorf("%s: err %v", bad, err)
		}
	}
	write(t, filepath.Join(dir, "ok.yaml"), "servers:\n  x:\n    command: a\n    env: {T: \"${keychain:svc/me}\", U: \"${HOME}\"}\n")
	if _, err := Load(filepath.Join(dir, "ok.yaml")); err != nil {
		t.Errorf("good refs: %v", err)
	}
}
