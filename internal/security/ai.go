package security

import (
	"encoding/json"
	"maps"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// mcpConfigs are the JSON files where AI clients keep their MCP servers,
// relative to the home folder.
var mcpConfigs = []string{
	".claude.json",
	".cursor/mcp.json",
	".gemini/settings.json",
	".codeium/windsurf/mcp_config.json",
	"Library/Application Support/Claude/claude_desktop_config.json",
}

// claudeSettings hold Claude Code's permission rules.
var claudeSettings = []string{".claude/settings.json", ".claude/settings.local.json"}

type mcpServer struct {
	Command string            `json:"command"`
	Args    []string          `json:"args"`
	Env     map[string]string `json:"env"`
	Headers map[string]string `json:"headers"`
}

var (
	secretName = regexp.MustCompile(`(?i)(key|token|secret|password|auth)`)
	// tomlSecret is a secret-named key set to a literal in Codex's TOML.
	tomlSecret = regexp.MustCompile(`(?im)^\s*"?([a-z0-9_]*(?:key|token|secret|password)[a-z0-9_]*)"?\s*=\s*"[^"$]{8,}"`)
)

// AI checks the configs that give AI agents tools: MCP servers holding API
// keys in plain text, MCP servers that run whatever version a package
// registry serves today, and Claude Code permission rules that let any shell
// command run without a question.
func (u User) AI() []Result {
	servers := map[string]map[string]mcpServer{} // file -> name -> server
	for _, f := range mcpConfigs {
		var doc struct {
			MCPServers map[string]mcpServer `json:"mcpServers"`
			Projects   map[string]struct {
				MCPServers map[string]mcpServer `json:"mcpServers"`
			} `json:"projects"`
		}
		if !u.readJSON(f, &doc) {
			continue
		}
		all := maps.Clone(doc.MCPServers)
		if all == nil {
			all = map[string]mcpServer{}
		}
		for _, p := range doc.Projects {
			maps.Copy(all, p.MCPServers)
		}
		servers["~/"+f] = all
	}
	return []Result{u.plaintextKeys(servers), unpinned(servers), u.broadPermissions()}
}

func (u User) readJSON(rel string, v any) bool {
	b, err := os.ReadFile(filepath.Join(u.home, rel))
	return err == nil && json.Unmarshal(b, v) == nil
}

func (u User) plaintextKeys(servers map[string]map[string]mcpServer) Result {
	const name = "AI configs hold no plain-text keys"
	var found []string
	for _, file := range sortedKeys(servers) {
		for _, n := range sortedKeys(servers[file]) {
			s := servers[file][n]
			for _, vars := range []map[string]string{s.Env, s.Headers} {
				for _, k := range sortedKeys(vars) {
					if secretName.MatchString(k) && literal(vars[k]) {
						found = append(found, file+" "+n+"."+k)
					}
				}
			}
		}
	}
	if b, err := os.ReadFile(filepath.Join(u.home, ".codex", "config.toml")); err == nil {
		for _, m := range tomlSecret.FindAllStringSubmatch(string(b), -1) {
			found = append(found, "~/.codex/config.toml "+m[1])
		}
	}
	if len(found) == 0 {
		return Result{Name: name, OK: true}
	}
	return Result{Name: name, Warn: true, Detail: strings.Join(found, ", ") +
		"; move each key to the keychain or a password manager and pass it in as ${VAR}"}
}

// literal is a value written out, not a reference to the environment.
func literal(v string) bool {
	return len(v) >= 8 && !strings.HasPrefix(v, "$") && !strings.Contains(v, "{{")
}

// unpinned names MCP servers started through npx, bunx or uvx without a
// version: each start runs whatever the registry serves that day.
func unpinned(servers map[string]map[string]mcpServer) Result {
	const name = "MCP servers pinned to a version"
	var found []string
	for _, file := range sortedKeys(servers) {
		for _, n := range sortedKeys(servers[file]) {
			if pkg, ok := floating(servers[file][n]); ok {
				found = append(found, file+" "+n+" ("+pkg+")")
			}
		}
	}
	if len(found) == 0 {
		return Result{Name: name, OK: true}
	}
	return Result{Name: name, Warn: true, Detail: strings.Join(found, ", ") +
		"; name a version, such as pkg@1.2.3, and update it on purpose"}
}

// floating returns the package a runner starts when no version pins it.
func floating(s mcpServer) (string, bool) {
	runner := path.Base(filepath.ToSlash(s.Command))
	if !slices.Contains([]string{"npx", "bunx", "uvx", "pnpx"}, runner) {
		return "", false
	}
	for _, a := range s.Args {
		if strings.HasPrefix(a, "-") {
			continue
		}
		if runner == "uvx" {
			return a, !strings.Contains(a, "==") && !strings.Contains(a, "@")
		}
		// A scoped package starts with @; its version follows the next @.
		at := strings.LastIndex(a, "@")
		version := ""
		if at > 0 {
			version = a[at+1:]
		}
		return a, version == "" || version == "latest"
	}
	return "", false
}

func (u User) broadPermissions() Result {
	const name = "Claude Code asks before shell commands"
	var found []string
	for _, f := range claudeSettings {
		var doc struct {
			Permissions struct {
				Allow       []string `json:"allow"`
				DefaultMode string   `json:"defaultMode"`
			} `json:"permissions"`
		}
		if !u.readJSON(f, &doc) {
			continue
		}
		for _, rule := range doc.Permissions.Allow {
			if slices.Contains([]string{"Bash", "Bash(*)", "Bash(:*)", "Bash(**)"}, strings.ReplaceAll(rule, " ", "")) {
				found = append(found, "~/"+f+" allows "+rule)
			}
		}
		if doc.Permissions.DefaultMode == "bypassPermissions" {
			found = append(found, "~/"+f+" sets defaultMode bypassPermissions")
		}
	}
	if len(found) == 0 {
		return Result{Name: name, OK: true}
	}
	return Result{Name: name, Warn: true, Detail: strings.Join(found, ", ") +
		"; allow the commands you run, such as Bash(git status:*), and keep the sandbox on"}
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}
