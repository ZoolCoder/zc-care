package security

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/sh"
)

// pem wraps body in the armour of a key file of kind. The armour is built
// here so secret scanners do not take the fixtures for keys.
func pem(kind, body string) string {
	return "-----BEGIN " + kind + " PRIVATE" + " KEY-----\n" + body + "-----END " + kind + " PRIVATE" + " KEY-----\n"
}

func sshField(b []byte, field string) []byte {
	return append(binary.BigEndian.AppendUint32(b, uint32(len(field))), field...)
}

// opensshKey is a key file whose header names cipher and holds a key of
// keyType.
func opensshKey(cipher, keyType string) string {
	raw := sshField([]byte("openssh-key-v1\x00"), cipher)
	raw = sshField(raw, "none")
	raw = sshField(raw, "")
	raw = binary.BigEndian.AppendUint32(raw, 1)
	raw = sshField(raw, string(sshField(nil, keyType)))
	return pem("OPENSSH", base64.StdEncoding.EncodeToString(raw)+"\n")
}

func home(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func byName(results []Result) map[string]Result {
	got := map[string]Result{}
	for _, r := range results {
		got[r.Name] = r
	}
	return got
}

const gitleaksScan = "--no-banner --redact --report-format json --report-path - --exit-code 0"

func TestAccountChecks(t *testing.T) {
	dir := home(t, map[string]string{
		".ssh/id_ed25519":     opensshKey("none", "ssh-ed25519"),
		".ssh/id_ed25519.pub": "ssh-ed25519 AAAA me",
		".ssh/work":           opensshKey("aes256-ctr", "ssh-ed25519"),
		".ssh/fido":           opensshKey("none", "sk-ssh-ed25519@openssh.com"),
		".ssh/old_rsa":        pem("RSA", "Proc-Type: 4,ENCRYPTED\n"),
		".ssh/config":         "Host *\n",
		".zsh_history":        "export TOKEN=x\n",
	})
	f := &sh.Fake{Programs: []string{"gitleaks"}, Out: map[string]string{
		"git config --global --includes --get commit.gpgsign":                     "false\n",
		"gitleaks dir " + filepath.Join(dir, ".zsh_history") + " " + gitleaksScan: `[{"RuleID":"github-pat","Secret":"REDACTED"},{"RuleID":"github-pat"}]`,
	}}
	got := byName(User{r: f, home: dir}.Account(context.Background()))
	if r := got["SSH keys have a passphrase"]; !r.Warn || !strings.HasPrefix(r.Detail, "id_ed25519 open") || strings.Contains(r.Detail, "fido") {
		t.Errorf("ssh: %+v", r)
	}
	if r := got["git signs commits"]; !r.Warn {
		t.Errorf("signing: %+v", r)
	}
	r := got["no secrets in shell history"]
	if !r.Warn || !strings.HasPrefix(r.Detail, "~/.zsh_history: github-pat x2;") || strings.Contains(r.Detail, "REDACTED") {
		t.Errorf("history: %+v", r)
	}
}

func TestHistoryScanThatFailedIsNotClean(t *testing.T) {
	dir := home(t, map[string]string{".zsh_history": "ls\n", ".bash_history": "ls\n"})
	scan := func(file string) string { return "gitleaks dir " + filepath.Join(dir, file) + " " + gitleaksScan }
	cases := map[string]*sh.Fake{
		"command error": {Programs: []string{"gitleaks"}, Err: map[string]error{scan(".zsh_history"): errors.New("gitleaks: exit status 2: bad flag")},
			Out: map[string]string{scan(".bash_history"): "[]"}},
		"empty report": {Programs: []string{"gitleaks"}, Out: map[string]string{scan(".zsh_history"): "", scan(".bash_history"): "[]"}},
		"not an array": {Programs: []string{"gitleaks"}, Out: map[string]string{scan(".zsh_history"): `{"x":1}`, scan(".bash_history"): "[]"}},
	}
	for name, f := range cases {
		r := User{r: f, home: dir}.historySecrets(context.Background())
		if !r.Warn || !strings.HasPrefix(r.Detail, "gitleaks failed: ~/.zsh_history") {
			t.Errorf("%s: %+v", name, r)
		}
	}
	clean := &sh.Fake{Programs: []string{"gitleaks"}, Out: map[string]string{scan(".zsh_history"): "[]", scan(".bash_history"): "[\n]"}}
	if r := (User{r: clean, home: dir}).historySecrets(context.Background()); !r.OK {
		t.Errorf("clean: %+v", r)
	}
}

func TestAtuinHistoryFailsTheScanWhenAtuinFails(t *testing.T) {
	dir := home(t, nil)
	line := "/bin/sh -c set -o pipefail; atuin history list --cmd-only | gitleaks stdin " + gitleaksScan
	f := &sh.Fake{Programs: []string{"gitleaks", "atuin"}, Err: map[string]error{line: errors.New("atuin: exit status 1: no database")}}
	r := User{r: f, home: dir}.historySecrets(context.Background())
	if !r.Warn || !strings.Contains(r.Detail, "gitleaks failed: atuin: ") {
		t.Errorf("%+v", r)
	}
}

func TestAIChecks(t *testing.T) {
	dir := home(t, map[string]string{
		".claude.json": `{"mcpServers":{"gh":{"command":"npx","args":["-y","@modelcontextprotocol/server-github"],"env":{"GITHUB_TOKEN":"ghp_abcdefghijkl"}}},
			"projects":{"/p":{"mcpServers":{"pg":{"command":"npx","args":["-y","pg-mcp@1.4.0"],"env":{"PG_PASSWORD":"${PG_PASSWORD}"}}}}}}`,
		".cursor/mcp.json":      `{"mcpServers":{"ctx":{"command":"/opt/homebrew/bin/npx","args":["ctx7@latest"]},"local":{"command":"/usr/local/bin/srv"}}}`,
		".codex/config.toml":    "[mcp_servers.x.env]\nAPI_KEY = \"sk-1234567890\"\nOTHER = \"${OTHER}\"\n",
		".claude/settings.json": `{"permissions":{"allow":["Bash(git status:*)","Bash(*)"],"defaultMode":"bypassPermissions"}}`,
	})
	got := byName(User{home: dir}.AI())
	if r := got["AI configs hold no plain-text keys"]; !r.Warn || !strings.HasPrefix(r.Detail, "~/.claude.json gh.GITHUB_TOKEN, ~/.codex/config.toml API_KEY;") || strings.Contains(r.Detail, "ghp_") {
		t.Errorf("keys: %+v", r)
	}
	if r := got["MCP servers pinned to a version"]; !r.Warn ||
		r.Detail != "~/.claude.json gh (@modelcontextprotocol/server-github), ~/.cursor/mcp.json ctx (ctx7@latest); name a version, such as pkg@1.2.3, and update it on purpose" {
		t.Errorf("pinned: %+v", r)
	}
	if r := got["Claude Code asks before shell commands"]; !r.Warn || strings.Count(r.Detail, "~/.claude/settings.json") != 2 {
		t.Errorf("permissions: %+v", r)
	}
	for _, r := range (User{home: t.TempDir()}).AI() {
		if !r.OK {
			t.Errorf("empty home: %+v", r)
		}
	}
}

func TestProjectServersKeepTheirOwnNamesAndProjectFile(t *testing.T) {
	proj := t.TempDir()
	dir := home(t, nil)
	write := func(file, body string) {
		if err := os.WriteFile(file, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	other := t.TempDir()
	write(filepath.Join(dir, ".claude.json"), `{"projects":{
		"`+proj+`":{"mcpServers":{"db":{"command":"npx","args":["a@latest"]}}},
		"`+other+`":{"mcpServers":{"db":{"command":"npx","args":["b@latest"]}}}}}`)
	write(filepath.Join(proj, ".mcp.json"), `{"mcpServers":{"shared":{"command":"uvx","args":["tool"],"env":{"API_KEY":"abcdefghijkl"}}}}`)
	got := byName(User{home: dir}.AI())
	pinned := got["MCP servers pinned to a version"].Detail
	for _, want := range []string{"#" + proj + " db (a@latest)", "#" + other + " db (b@latest)", proj + "/.mcp.json shared (tool)"} {
		if !strings.Contains(pinned, want) {
			t.Errorf("pinned %q lacks %q", pinned, want)
		}
	}
	if keys := got["AI configs hold no plain-text keys"].Detail; !strings.Contains(keys, "/.mcp.json shared.API_KEY") {
		t.Errorf("keys: %q", keys)
	}
}

func TestFloatingNeedsAnExactVersion(t *testing.T) {
	cases := []struct {
		command string
		args    []string
		want    string // the floating package, or "" when pinned
	}{
		{"npx", []string{"-y", "pkg@1.2.3"}, ""},
		{"npx", []string{"-y", "@scope/pkg@1.2.3"}, ""},
		{"npx", []string{"-y", "pkg@1.2.3-beta.1"}, ""},
		{"npx", []string{"pkg"}, "pkg"},
		{"npx", []string{"pkg@latest"}, "pkg@latest"},
		{"npx", []string{"pkg@beta"}, "pkg@beta"},
		{"npx", []string{"pkg@next"}, "pkg@next"},
		{"npx", []string{"pkg@^1.2.3"}, "pkg@^1.2.3"},
		{"npx", []string{"pkg@1"}, "pkg@1"},
		{"npx", []string{"pkg@1.2"}, "pkg@1.2"},
		{"npx", []string{"-p", "pkg", "cmd@1.0.0"}, "pkg"},
		{"npx", []string{"-p", "pkg@2.0.0", "cmd"}, ""},
		{"npx", []string{"--package=pkg@latest", "cmd"}, "pkg@latest"},
		{"npx", []string{"--package", "pkg@2.0.0", "cmd"}, ""},
		{"npx", []string{"--registry", "https://r.example", "pkg@1.0.0"}, ""},
		{"uvx", []string{"pkg@latest"}, "pkg@latest"},
		{"uvx", []string{"pkg"}, "pkg"},
		{"uvx", []string{"pkg==1.2.3"}, ""},
		{"uvx", []string{"pkg>=1.0"}, "pkg>=1.0"},
		{"uvx", []string{"pkg==1.*"}, "pkg==1.*"},
		{"uvx", []string{"pkg@1.2.3"}, ""},
		{"uvx", []string{"--from", "pkg", "cmd"}, "pkg"},
		{"uvx", []string{"--from=pkg==1.2.3", "cmd"}, ""},
		{"uvx", []string{"--python", "3.12", "pkg==1.2.3"}, ""},
		{"uvx", []string{"-p", "3.12", "pkg"}, "pkg"},
		{"/usr/local/bin/srv", []string{"pkg"}, ""},
	}
	for _, c := range cases {
		got, floats := floating(mcpServer{Command: c.command, Args: c.args})
		if floats != (c.want != "") || got != c.want {
			t.Errorf("%s %v: %q %v, want %q", c.command, c.args, got, floats, c.want)
		}
	}
}

func TestSecretsInAnyPlaceButReferences(t *testing.T) {
	s := mcpServer{
		Args: []string{"--api-key=abcdefghij", "--token=${TOKEN}", "--author=somebodyelse", "https://x.example/mcp?key=abcdefghij&q=1"},
		URL:  "https://y.example/mcp?token=abcdefghij",
		Headers: map[string]string{
			"Authorization": "Bearer ${GITHUB_TOKEN}",
			"X-Api-Key":     "Basic abcdefghijkl",
			"Author":        "somebodyelse",
		},
		Env: map[string]string{"MONKEY": "bananabanana", "apiKey": "abcdefghijkl", "OAUTH_TOKEN": "$OAUTH"},
	}
	want := []string{"X-Api-Key", "apiKey", "--api-key", "url?key", "url?token"}
	got := s.literalSecrets()
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
	if literal("Bearer ${GITHUB_TOKEN}") || !literal("Bearer ghp_abcdefghij") {
		t.Error("a Bearer reference is not a literal, a Bearer token is")
	}
}
