package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// runSplit is run with stdout and stderr kept apart.
func runSplit(t *testing.T, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	var out, errOut bytes.Buffer
	err = runCLI(args, strings.NewReader(""), &out, &errOut)
	return out.String(), errOut.String(), err
}

func TestDiffShortHashDoesNotPanic(t *testing.T) {
	dir := t.TempDir()
	write := func(file, hash string) string {
		path := filepath.Join(dir, file)
		body := fmt.Sprintf(`{"version":1,"host":"h","macos":"1","date":"d","targets":[{"name":"dots","provider":"dotfiles","items":[{"kind":"dotfile","name":".zshrc","state":"in place","hash":%q}]}]}`, hash)
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	a, b := write("a.json", "abc"), write("b.json", "abd")
	out, err := run(t, "", "diff", a, b)
	if err != nil || !strings.Contains(out, "sha256:abc -> sha256:abd") {
		t.Fatalf("diff: %v\n%s", err, out)
	}
}

func TestDiffExitCodeSignalsDifferences(t *testing.T) {
	dir := t.TempDir()
	snap := func(file, state string) string {
		path := filepath.Join(dir, file)
		body := fmt.Sprintf(`{"version":1,"targets":[{"name":"p","provider":"packages","items":[{"kind":"brew","name":"jq","state":%q,"version":"1"}]}]}`, state)
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	same, gone := snap("same.json", "in place"), snap("gone.json", "missing")
	if _, err := run(t, "", "diff", "-exit-code", same, same); err != nil {
		t.Fatalf("same: %v", err)
	}
	if _, err := run(t, "", "diff", "-exit-code", same, gone); !errors.Is(err, errDrift) {
		t.Fatalf("differ: %v", err)
	}
	if _, err := run(t, "", "diff", same, gone); err != nil {
		t.Fatalf("without -exit-code: %v", err)
	}
}

func TestUpgradeReportsErroredTarget(t *testing.T) {
	list := `[{"target":"pkgs","provider":"packages","error":"brew: executable file not found in $PATH"}]`
	file, err := saveOutdated([]byte(list))
	if err == nil || file != "" || !strings.Contains(err.Error(), "pkgs") {
		t.Fatalf("file %q, err %v", file, err)
	}
	if file, err := saveOutdated([]byte(`[{"target":"pkgs","provider":"packages"}]`)); err != nil || file != "" {
		t.Fatalf("nothing outdated: %q, %v", file, err)
	}
}

func TestExitCodes(t *testing.T) {
	cfg, _ := fixture(t)
	_, err := run(t, "", "plan", "-config", cfg, "-exit-code")
	cases := []struct {
		name string
		err  error
		want int
	}{
		{"nil", nil, 0},
		{"plan -exit-code with changes", err, 2},
		{"drift", errDrift, 2},
		{"manual only", errManualOnly, 3},
		{"wrapped manual only", fmt.Errorf("x: %w", errManualOnly), 3},
		{"cancelled", errCancelled, 1},
		{"plain", errors.New("boom"), 1},
	}
	for _, c := range cases {
		if got := exitCode(c.err); got != c.want {
			t.Errorf("%s: exit %d, want %d", c.name, got, c.want)
		}
	}
}

// flagLine is a flag in the list flag.PrintDefaults prints.
var flagLine = regexp.MustCompile(`(?m)^  -(\S+)`)

func TestHelpFlagExitsZero(t *testing.T) {
	cmds := []string{"plan", "apply", "status", "list", "capture", "validate", "doctor", "upgrade", "history", "drift", "undo"}
	for cmd := range optional {
		cmds = append(cmds, cmd)
	}
	slices.Sort(cmds)
	for _, cmd := range cmds {
		_, stderr, err := runSplit(t, cmd, "-h")
		if err != nil {
			t.Errorf("%s -h: %v", cmd, err)
			continue
		}
		help := stderr
		if _, after, ok := strings.Cut(stderr, flagsHeading+cmd+":"); ok {
			help = after
		}
		for _, m := range flagLine.FindAllStringSubmatch(help, -1) {
			if m[1] == "via" || m[1] == "h" {
				continue
			}
			if !regexp.MustCompile(`(^|[^\w-])-` + regexp.QuoteMeta(m[1]) + `([^\w-]|$)`).MatchString(usage()) {
				t.Errorf("%s has -%s, which the usage text does not list", cmd, m[1])
			}
		}
	}
}

func TestMCPHelpPrintsUsageInsteadOfServing(t *testing.T) {
	_, stderr, err := runSplit(t, "mcp", "-h")
	if err != nil || !strings.Contains(stderr, "stdio MCP server") {
		t.Fatalf("%v: %s", err, stderr)
	}
}

func TestApplyJSONShape(t *testing.T) {
	cfg, _ := fixture(t)
	stdout, stderr, err := runSplit(t, "apply", "-config", cfg, "-json")
	if err != nil {
		t.Fatalf("apply: %v\n%s", err, stderr)
	}
	var r struct {
		Applied     []struct{ Target, Resource string }
		Failed      []any
		Outstanding []any
		Verified    bool
	}
	if err := json.Unmarshal([]byte(stdout), &r); err != nil {
		t.Fatalf("stdout is not JSON: %v\n%s", err, stdout)
	}
	if len(r.Applied) != 1 || r.Applied[0].Resource != "a.txt" || len(r.Failed) != 0 || len(r.Outstanding) != 0 || !r.Verified {
		t.Fatalf("result %+v\n%s", r, stdout)
	}
	if !strings.Contains(stderr, "CREATE") {
		t.Fatalf("the plan should go to stderr:\n%s", stderr)
	}
	stdout, _, err = runSplit(t, "apply", "-config", cfg, "-json")
	if err != nil || !strings.Contains(stdout, `"applied": []`) || !strings.Contains(stdout, `"verified": true`) {
		t.Fatalf("converged: %v\n%s", err, stdout)
	}
}

func TestValidateJSONShape(t *testing.T) {
	cfg, _ := fixture(t)
	stdout, _, err := runSplit(t, "validate", "-config", cfg, "-json")
	var r struct {
		Config  string
		Targets int
		Valid   bool
		Errors  []string
	}
	if err != nil || json.Unmarshal([]byte(stdout), &r) != nil || r.Config != cfg || r.Targets != 1 || !r.Valid || r.Errors == nil || len(r.Errors) != 0 {
		t.Fatalf("valid: %v %+v\n%s", err, r, stdout)
	}
	missing := filepath.Join(t.TempDir(), "none.yaml")
	stdout, _, err = runSplit(t, "validate", "-config", missing, "-json")
	r.Errors = nil
	if err == nil || json.Unmarshal([]byte(stdout), &r) != nil || r.Valid || len(r.Errors) != 1 {
		t.Fatalf("invalid: %v %+v\n%s", err, r, stdout)
	}
}

func TestCaptureRejectsJSON(t *testing.T) {
	cfg, _ := fixture(t)
	if _, err := run(t, "", "capture", "-config", cfg, "-json"); err == nil || !strings.Contains(err.Error(), "-json") {
		t.Fatalf("err %v", err)
	}
}

func TestExportNeedsForceToOverwrite(t *testing.T) {
	cfg, _ := fixture(t)
	file := filepath.Join(t.TempDir(), "snap.json")
	if _, err := run(t, "", "export", "-config", cfg, "-o", file); err != nil {
		t.Fatal(err)
	}
	if _, err := run(t, "", "export", "-config", cfg, "-o", file); err == nil || !strings.Contains(err.Error(), "-force") {
		t.Fatalf("overwrote without -force: %v", err)
	}
	if _, err := run(t, "", "export", "-config", cfg, "-o", file, "-force"); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Stat(file); info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", info.Mode().Perm())
	}
}

func TestDriftHourAndConfigAreChecked(t *testing.T) {
	if _, err := run(t, "", "drift", "-plist", "-hour", "24"); err == nil || !strings.Contains(err.Error(), "0 to 23") {
		t.Fatalf("hour: %v", err)
	}
	if _, err := run(t, "", "drift", "-plist", "-config", "-"); err == nil {
		t.Fatal("-config - accepted for the plist")
	}
}

func TestDriftFailsWhenItCannotPlan(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "none.yaml")
	if _, err := run(t, "", "drift", "-config", missing); err == nil {
		t.Fatal("a failed plan exited 0")
	}
}

func TestHistoryRejectsANonPositiveCount(t *testing.T) {
	for _, n := range []string{"0", "-1"} {
		if _, err := run(t, "", "history", "-n", n); err == nil {
			t.Fatalf("-n %s accepted", n)
		}
	}
}

func TestInitRejectsABadProfile(t *testing.T) {
	if _, err := run(t, "", "init", "-profile", "Not Kebab", "-dir", t.TempDir()); err == nil {
		t.Fatal("bad profile accepted")
	}
}
