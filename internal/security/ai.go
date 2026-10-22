package security

import (
	"bytes"
	"encoding/json"
	"errors"
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
	Command string
	Args    []string
	URL     string
	Env     map[string]string
	Headers map[string]string
}

// UnmarshalJSON rejects anything but an object (or null), so a malformed entry
// is reported instead of passing every check. It reads a server field by field, turning a number or boolean
// into its text, so one value of the wrong type (a numeric PORT) cannot make
// the whole config unreadable and let its keys go unchecked.
func (s *mcpServer) UnmarshalJSON(b []byte) error {
	var raw map[string]json.RawMessage
	if t := bytes.TrimSpace(b); string(t) == "null" {
		return nil
	} else if len(t) == 0 || t[0] != '{' {
		return errors.New("server entry is not an object")
	}
	if json.Unmarshal(b, &raw) != nil {
		return nil
	}
	s.Command, s.URL = text(raw["command"]), text(raw["url"])
	s.Args, s.Env, s.Headers = texts(raw["args"]), textMap(raw["env"]), textMap(raw["headers"])
	return nil
}

// text is a JSON string, or the written form of a number or boolean; null,
// an object and an array have none.
func text(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	t := strings.TrimSpace(string(raw))
	if t == "null" || strings.HasPrefix(t, "{") || strings.HasPrefix(t, "[") {
		return ""
	}
	return t
}

func texts(raw json.RawMessage) []string {
	var list []json.RawMessage
	if json.Unmarshal(raw, &list) != nil {
		return nil
	}
	out := make([]string, len(list))
	for i, item := range list {
		out[i] = text(item)
	}
	return out
}

func textMap(raw json.RawMessage) map[string]string {
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return nil
	}
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[k] = text(v)
	}
	return out
}

var (
	camelBoundary = regexp.MustCompile(`([a-z0-9])([A-Z])`)
	// secretWord is a whole word in a name, so AUTHOR and MONKEY pass.
	secretWord = regexp.MustCompile(`(^|[^a-z])(api[-_]?key|key|token|secret|password|passwd|o?auth|authorization|credentials?)s?([^a-z]|$)`)
	// tomlSecret is a secret-named key set to a literal in Codex's TOML.
	tomlSecret = regexp.MustCompile(`(?im)^\s*"?([a-z0-9_]*(?:key|token|secret|password)[a-z0-9_]*)"?\s*=\s*"[^"$]+"`)
	// argSecret is a flag with its value attached, such as --api-key=abc.
	argSecret = regexp.MustCompile(`^--?([\w-]+)=(.+)$`)
	// urlSecret is a query parameter, such as ?key=abc.
	urlSecret = regexp.MustCompile(`[?&]([\w.-]+)=([^&#\s]+)`)
)

func isSecretName(name string) bool {
	return secretWord.MatchString(strings.ToLower(camelBoundary.ReplaceAllString(name, "${1}_${2}")))
}

// AI checks the configs that give AI agents tools: MCP servers holding API
// keys in plain text, MCP servers that run whatever version a package
// registry serves today, and Claude Code permission rules that let any shell
// command run without a question.
func (u User) AI() []Result {
	servers := map[string]map[string]mcpServer{} // where -> name -> server
	var unreadable []string
	for _, f := range mcpConfigs {
		var doc struct {
			MCPServers map[string]mcpServer `json:"mcpServers"`
			Projects   map[string]struct {
				MCPServers map[string]mcpServer `json:"mcpServers"`
			} `json:"projects"`
		}
		if !u.readJSON(f, &doc) {
			if _, err := os.Stat(filepath.Join(u.home, f)); err == nil {
				unreadable = append(unreadable, "~/"+f)
			}
			continue
		}
		servers["~/"+f] = doc.MCPServers
		for dir, p := range doc.Projects {
			servers["~/"+f+"#"+dir] = p.MCPServers
			if f == ".claude.json" {
				u.addProjectServers(servers, dir)
			}
		}
	}
	results := []Result{u.plaintextKeys(servers), unpinned(servers), u.broadPermissions()}
	if len(unreadable) > 0 {
		results = append(results, Result{Name: "AI configs can be read", Unknown: true,
			Detail: "could not parse " + strings.Join(unreadable, " ") + "; its servers were not checked"})
	}
	return results
}

// addProjectServers adds the servers a project shares in its own .mcp.json.
func (u User) addProjectServers(servers map[string]map[string]mcpServer, dir string) {
	if !filepath.IsAbs(dir) {
		return
	}
	file := filepath.Join(dir, ".mcp.json")
	var doc struct {
		MCPServers map[string]mcpServer `json:"mcpServers"`
	}
	if readJSONAt(file, &doc) {
		servers[strings.Replace(file, u.home+string(filepath.Separator), "~/", 1)] = doc.MCPServers
	}
}

func (u User) readJSON(rel string, v any) bool { return readJSONAt(filepath.Join(u.home, rel), v) }

func readJSONAt(file string, v any) bool {
	b, err := os.ReadFile(file)
	return err == nil && json.Unmarshal(b, v) == nil
}

func (u User) plaintextKeys(servers map[string]map[string]mcpServer) Result {
	const name = "AI configs hold no plain-text keys"
	var found []string
	for _, file := range slices.Sorted(maps.Keys(servers)) {
		for _, n := range slices.Sorted(maps.Keys(servers[file])) {
			for _, key := range servers[file][n].literalSecrets() {
				found = append(found, file+" "+n+"."+key)
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

// literalSecrets names where the server holds a secret written out: an env
// var or header, a --flag=value argument, or a query parameter in a URL.
func (s mcpServer) literalSecrets() []string {
	var found []string
	for _, vars := range []map[string]string{s.Env, s.Headers} {
		for _, k := range slices.Sorted(maps.Keys(vars)) {
			if isSecretName(k) && literal(vars[k]) {
				found = append(found, k)
			}
		}
	}
	for _, a := range s.Args {
		if m := argSecret.FindStringSubmatch(a); m != nil && isSecretName(m[1]) && literal(m[2]) {
			found = append(found, "--"+strings.TrimLeft(m[1], "-"))
		}
	}
	for _, u := range append([]string{s.URL}, s.Args...) {
		for _, m := range urlSecret.FindAllStringSubmatch(u, -1) {
			if isSecretName(m[1]) && literal(m[2]) {
				found = append(found, "url?"+m[1])
			}
		}
	}
	return found
}

// literal is a value written out, not a reference to the environment, of any
// length: a short secret is still a secret. An Authorization header keeps
// its scheme in front of the secret.
func literal(v string) bool {
	for _, scheme := range []string{"Bearer ", "Basic "} {
		if len(v) >= len(scheme) && strings.EqualFold(v[:len(scheme)], scheme) {
			v = strings.TrimSpace(v[len(scheme):])
			break
		}
	}
	return v != "" && !strings.HasPrefix(v, "$") && !strings.Contains(v, "${") && !strings.Contains(v, "{{")
}

// unpinned names MCP servers started through npx, bunx or uvx without an
// exact version: each start runs whatever the registry serves that day.
func unpinned(servers map[string]map[string]mcpServer) Result {
	const name = "MCP servers pinned to a version"
	var found []string
	for _, file := range slices.Sorted(maps.Keys(servers)) {
		for _, n := range slices.Sorted(maps.Keys(servers[file])) {
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

var (
	npmVersion = regexp.MustCompile(`^\d+\.\d+\.\d+([-+][0-9A-Za-z.+-]+)?$`)
	pyVersion  = regexp.MustCompile(`^\d[\w.+!-]*$`)
)

// exactVersion is pkg@1.2.3 or pkg==1.2.3; a tag (latest, beta), a range
// (^1.2, >=1) or a partial version (1, 1.2) moves.
func exactVersion(spec string) bool {
	if i := strings.Index(spec, "=="); i > 0 {
		return pyVersion.MatchString(spec[i+2:])
	}
	// A scoped package starts with @; its version follows the next @.
	at := strings.LastIndex(spec, "@")
	return at > 0 && npmVersion.MatchString(spec[at+1:])
}

// switches take no value, so the argument after one may be the package. Any
// other --flag written without = is taken to have a value, which is not a
// package and may be a secret.
var switches = []string{
	"--yes", "--no", "--quiet", "--silent", "--verbose", "--help", "--version", "--force", "--offline",
	"--no-install", "--no-cache", "--no-progress", "--no-fund", "--no-audit", "--no-update-notifier",
	"--ignore-existing", "--prefer-offline", "--isolated", "--refresh", "--no-sync", "--no-config",
}

// valueFlags take the next argument as their value, which is not a package.
var valueFlags = []string{
	"-c", "--call", "--registry", "--token", "--auth-token", "--scope", "--otp", "--prefix", "--cache", "--node-options", "--userconfig",
	"--python", "--with", "--with-requirements", "--index", "--index-url", "--env-file", "--directory",
}

// packages are the specs a runner fetches: those named by -p, --package or
// --from, else the first argument that is not an option.
func packages(runner string, args []string) []string {
	var named []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		flag, value, attached := strings.Cut(a, "=")
		switch {
		case flag == "--package" || flag == "--from" || (flag == "-p" && runner != "uvx"):
			if !attached && i+1 < len(args) {
				value = args[i+1]
				i++
			}
			named = append(named, value)
		case slices.Contains(valueFlags, flag) || (flag == "-p" && runner == "uvx"):
			if !attached {
				i++
			}
		case strings.HasPrefix(a, "--") && a != "--" && !attached && !slices.Contains(switches, flag):
			// An unknown flag may or may not take a value: the next word is
			// the package when it is name-shaped, else skipped as a value.
			if i+1 < len(args) && !nameShaped(args[i+1]) {
				i++
			}
		case strings.HasPrefix(a, "-"):
		case len(named) > 0:
			return named
		default:
			return []string{a}
		}
	}
	return named
}

// secretLook is a word that reads as a token, not a package name.
var secretLook = regexp.MustCompile(`^(ghp_|gho_|ghs_|github_pat_|sk-|xox|npm_|glpat-)`)

// nameShaped is a word fit to be a package name: it has no =, is no option
// and does not look like a token.
func nameShaped(word string) bool {
	return packageSpec.MatchString(word) && !strings.HasPrefix(word, "-") && !secretLook.MatchString(word)
}

// packageSpec is [@scope/]name with an optional version or specifier: all
// that is safe to print. Any other argument could be a secret.
var packageSpec = regexp.MustCompile(`^(@[\w.-]+/)?[\w.-]+([@=<>~!^*][\w.=<>~!^*+,@-]*)?$`)

// floating returns the first package a runner starts without an exact
// version, as a name fit to print.
func floating(s mcpServer) (string, bool) {
	runner, args := runnerOf(s)
	if runner == "" {
		return "", false
	}
	for _, pkg := range packages(runner, args) {
		if !exactVersion(pkg) {
			if !packageSpec.MatchString(pkg) {
				pkg = "unrecognised spec"
			}
			return pkg, true
		}
	}
	return "", false
}

// runnerOf names the package runner a server starts and the arguments after
// it: npx, bunx, uvx and pnpx, or the same through npm exec, pnpm dlx,
// yarn dlx and bun x. It is empty for any other command.
func runnerOf(s mcpServer) (string, []string) {
	command := path.Base(filepath.ToSlash(s.Command))
	if slices.Contains([]string{"npx", "bunx", "uvx", "pnpx"}, command) {
		return command, s.Args
	}
	subcommands := map[string][]string{"npm": {"exec", "x"}, "pnpm": {"dlx", "exec"}, "yarn": {"dlx"}, "bun": {"x"}}
	if len(s.Args) > 0 && slices.Contains(subcommands[command], s.Args[0]) {
		return "npx", s.Args[1:]
	}
	return "", nil
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
