package agents

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/zoolcoder/zc-care/internal/manifest"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
)

// client is where one agent keeps its settings, relative to the home folder.
type client struct {
	servers string // MCP config: JSON with an mcpServers object, or Codex's TOML
	rules   string // standing instructions; empty when the client keeps them elsewhere
	skills  string // skills folder; empty when the client has none
	// entry is the server as this client's config spells it.
	entry func(Server) map[string]any
}

var clients = map[string]client{
	"claude": {servers: ".claude.json", rules: ".claude/CLAUDE.md", skills: ".claude/skills",
		entry: func(s Server) map[string]any {
			if s.URL != "" {
				return compact(map[string]any{"type": "http", "url": s.URL, "headers": s.Headers})
			}
			return compact(map[string]any{"type": "stdio", "command": s.Command, "args": s.Args, "env": s.Env})
		}},
	"cursor": {servers: ".cursor/mcp.json", entry: plain("url")},
	"gemini": {servers: ".gemini/settings.json", rules: ".gemini/GEMINI.md", entry: plain("httpUrl")},
	"codex":  {servers: ".codex/config.toml", rules: ".codex/AGENTS.md", skills: ".codex/skills"},
}

// plain is the spelling Cursor and Gemini share, apart from the URL's key.
func plain(urlKey string) func(Server) map[string]any {
	return func(s Server) map[string]any {
		if s.URL != "" {
			return compact(map[string]any{urlKey: s.URL, "headers": s.Headers})
		}
		return compact(map[string]any{"command": s.Command, "args": s.Args, "env": s.Env})
	}
}

// compact drops empty fields, so a server without env has no env key.
func compact(m map[string]any) map[string]any {
	for k, v := range m {
		switch v := v.(type) {
		case string:
			if v == "" {
				delete(m, k)
			}
		case []string:
			if len(v) == 0 {
				delete(m, k)
			}
		case map[string]string:
			if len(v) == 0 {
				delete(m, k)
			}
		}
	}
	return m
}

// server compares one declared server with the client's config.
func (p Provider) server(target, clientName string, c client, name string, s Server, secret bool) (change, error) {
	path := filepath.Join(p.home, c.servers)
	resource := name + " (" + clientName + ")"
	ch := change{item: item(name, "mcp server", clientName, provider.InPlace)}
	have, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return change{}, err
	}
	var op plan.Op
	var write func([]byte) ([]byte, error)
	if c.entry == nil {
		op, write, err = codexServer(have, name, s)
	} else {
		op, write, err = jsonServer(have, name, c.entry(s))
	}
	if err != nil {
		return change{}, fmt.Errorf("~/%s: %w", c.servers, err)
	}
	switch op {
	case "":
		return ch, nil
	case plan.OpManual:
		ch.item.State = provider.Manual
		ch.action = plan.Action{Op: op, Target: target, Resource: resource,
			Detail: "~/" + c.servers + " declares " + name + " outside the managed block; remove it there first"}
		return ch, nil
	case plan.OpCreate:
		ch.item.State = provider.Missing
	default:
		ch.item.State = provider.Differs
	}
	ch.action = plan.Action{Op: op, Target: target, Resource: resource, Detail: "write to ~/" + c.servers,
		Do: func(context.Context) error {
			// Read again: the agent may have written the file since the plan.
			now, seen, err := readStamped(path)
			if err != nil {
				return err
			}
			next, err := write(now)
			if err != nil {
				return err
			}
			if bytes.Equal(now, next) || jsonEqual(now, next) {
				return nil
			}
			if err := unchanged(path, seen); err != nil {
				return err
			}
			return writeFile(path, next, secret)
		}}
	return ch, nil
}

// readStamped reads path and notes its mtime and size; a missing file reads
// as empty with no stamp.
func readStamped(path string) ([]byte, os.FileInfo, error) {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	info, err := os.Stat(path)
	return b, info, err
}

// unchanged fails when path is not as readStamped saw it: an agent writes its
// own config while we hold the copy we are about to replace.
func unchanged(path string, seen os.FileInfo) error {
	now, err := os.Stat(path)
	switch {
	case seen == nil && os.IsNotExist(err):
		return nil
	case err != nil || seen == nil,
		!now.ModTime().Equal(seen.ModTime()) || now.Size() != seen.Size():
		return fmt.Errorf("%s changed while zc-care was writing it; re-run", path)
	}
	return nil
}

// jsonServer sets mcpServers[name] and leaves every other key as it was.
func jsonServer(have []byte, name string, entry map[string]any) (plan.Op, func([]byte) ([]byte, error), error) {
	want, _ := json.Marshal(entry)
	_, servers, err := decode(have)
	if err != nil {
		return "", nil, err
	}
	write := func(now []byte) ([]byte, error) {
		doc, servers, err := decode(now)
		if err != nil {
			return nil, err
		}
		servers[name] = want
		doc["mcpServers"], _ = json.Marshal(servers)
		out, err := json.MarshalIndent(doc, "", "  ")
		return append(out, '\n'), err
	}
	cur, ok := servers[name]
	switch {
	case !ok:
		return plan.OpCreate, write, nil
	case !jsonEqual(cur, want):
		return plan.OpUpdate, write, nil
	}
	return "", nil, nil
}

func decode(b []byte) (map[string]json.RawMessage, map[string]json.RawMessage, error) {
	doc := map[string]json.RawMessage{}
	servers := map[string]json.RawMessage{}
	if len(strings.TrimSpace(string(b))) == 0 {
		return doc, servers, nil
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		return nil, nil, err
	}
	if doc == nil { // the JSON was null
		doc = map[string]json.RawMessage{}
	}
	if raw, ok := doc["mcpServers"]; ok {
		if err := json.Unmarshal(raw, &servers); err != nil {
			return nil, nil, fmt.Errorf("mcpServers: %w", err)
		}
	}
	if servers == nil {
		servers = map[string]json.RawMessage{}
	}
	return doc, servers, nil
}

const (
	codexBegin = "# zc-care agents: begin (generated from the agents manifest)"
	codexEnd   = "# zc-care agents: end"
)

// codexServer keeps the server as a table inside a marked block of Codex's
// config.toml. Codex reads TOML, and a table declared twice breaks the file,
// so a server already declared outside the block is left to the user.
func codexServer(have []byte, name string, s Server) (plan.Op, func([]byte) ([]byte, error), error) {
	text := string(have)
	if _, err := withBlock(text, codexBegin, codexEnd, ""); err != nil {
		return "", nil, err
	}
	inside, outside := splitBlock(text)
	header := regexp.MustCompile(`(?m)^\[mcp_servers\.` + regexp.QuoteMeta(manifest.TOMLKey(name)) + `(\.[a-z_]+)?\]`)
	if header.MatchString(outside) {
		return plan.OpManual, nil, nil
	}
	tables := codexTables(inside)
	want := codexTable(name, s)
	write := func(now []byte) ([]byte, error) {
		inside, _ := splitBlock(string(now))
		tables := codexTables(inside)
		tables[name] = want
		var body strings.Builder
		for _, n := range slices.Sorted(maps.Keys(tables)) {
			body.WriteString(tables[n])
		}
		out, err := withBlock(string(now), codexBegin, codexEnd, body.String())
		return []byte(out), err
	}
	switch cur, ok := tables[name]; {
	case !ok:
		return plan.OpCreate, write, nil
	case cur != want:
		return plan.OpUpdate, write, nil
	}
	return "", nil, nil
}

// splitBlock returns the managed block's body and the text around it.
func splitBlock(text string) (inside, outside string) {
	i := strings.Index(text, codexBegin)
	if i < 0 {
		return "", text
	}
	j := strings.Index(text[i:], codexEnd)
	if j < 0 {
		return "", text
	}
	return text[i+len(codexBegin) : i+j], text[:i] + text[i+j+len(codexEnd):]
}

var codexHeader = regexp.MustCompile(`(?m)^\[mcp_servers\.("[^"]+"|[A-Za-z0-9_-]+)\]\n`)

// codexTables splits the block into one string per server, keyed by name.
func codexTables(block string) map[string]string {
	tables := map[string]string{}
	locs := codexHeader.FindAllStringSubmatchIndex(block, -1)
	for i, l := range locs {
		end := len(block)
		if i+1 < len(locs) {
			end = locs[i+1][0]
		}
		name := block[l[2]:l[3]]
		if unq, err := strconv.Unquote(name); err == nil {
			name = unq
		}
		tables[name] = strings.TrimLeft(block[l[0]:end], "\n")
	}
	return tables
}

// codexTable renders one server. Codex passes a variable through by name,
// so an env value written as ${NAME} becomes an env_vars entry.
func codexTable(name string, s Server) string {
	var b strings.Builder
	key := "mcp_servers." + manifest.TOMLKey(name)
	fmt.Fprintf(&b, "[%s]\n", key)
	if s.URL != "" {
		fmt.Fprintf(&b, "url = %s\n", strconv.Quote(s.URL))
		if len(s.Headers) > 0 {
			fmt.Fprintf(&b, "http_headers = %s\n", inline(s.Headers))
		}
		return b.String()
	}
	fmt.Fprintf(&b, "command = %s\n", strconv.Quote(s.Command))
	if len(s.Args) > 0 {
		quoted := make([]string, len(s.Args))
		for i, a := range s.Args {
			quoted[i] = strconv.Quote(a)
		}
		fmt.Fprintf(&b, "args = [%s]\n", strings.Join(quoted, ", "))
	}
	env, pass := map[string]string{}, []string{}
	for _, k := range slices.Sorted(maps.Keys(s.Env)) {
		if s.Env[k] == "${"+k+"}" {
			pass = append(pass, strconv.Quote(k))
		} else {
			env[k] = s.Env[k]
		}
	}
	if len(pass) > 0 {
		fmt.Fprintf(&b, "env_vars = [%s]\n", strings.Join(pass, ", "))
	}
	if len(env) > 0 {
		fmt.Fprintf(&b, "env = %s\n", inline(env))
	}
	return b.String()
}

func inline(m map[string]string) string {
	pairs := make([]string, 0, len(m))
	for _, k := range slices.Sorted(maps.Keys(m)) {
		pairs = append(pairs, manifest.TOMLKey(k)+" = "+strconv.Quote(m[k]))
	}
	return "{ " + strings.Join(pairs, ", ") + " }"
}
