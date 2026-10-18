package security

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/sh"
)

// pem wraps body in the armour of a key file of kind. The armour is built
// here so secret scanners do not take the fixtures for keys.
func pem(kind, body string) string {
	return "-----BEGIN " + kind + " PRIVATE" + " KEY-----\n" + body + "-----END " + kind + " PRIVATE" + " KEY-----\n"
}

// opensshKey is a key file whose header names cipher.
func opensshKey(cipher string) string {
	raw := []byte("openssh-key-v1\x00")
	raw = binary.BigEndian.AppendUint32(raw, uint32(len(cipher)))
	raw = append(raw, cipher...)
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

func TestAccountChecks(t *testing.T) {
	dir := home(t, map[string]string{
		".ssh/id_ed25519":     opensshKey("none"),
		".ssh/id_ed25519.pub": "ssh-ed25519 AAAA me",
		".ssh/work":           opensshKey("aes256-ctr"),
		".ssh/old_rsa":        pem("RSA", "Proc-Type: 4,ENCRYPTED\n"),
		".ssh/config":         "Host *\n",
		".zsh_history":        "export TOKEN=x\n",
	})
	scan := "--no-banner --redact --report-format json --report-path - --exit-code 0"
	f := &sh.Fake{Programs: []string{"gitleaks"}, Out: map[string]string{
		"git config --global --includes --get commit.gpgsign":             "false\n",
		"gitleaks dir " + filepath.Join(dir, ".zsh_history") + " " + scan: `[{"RuleID":"github-pat","Secret":"REDACTED"},{"RuleID":"github-pat"}]`,
	}}
	got := byName(User{r: f, home: dir}.Account(context.Background()))
	if r := got["SSH keys have a passphrase"]; !r.Warn || !strings.HasPrefix(r.Detail, "id_ed25519 open") {
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
