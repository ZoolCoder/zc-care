package tools

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/provider"
	"github.com/zoolcoder/zc-care/internal/sh"
)

func TestAddKeepsATableHeaderWithAComment(t *testing.T) {
	file := filepath.Join(t.TempDir(), "mise.toml")
	if err := os.WriteFile(file, []byte("[tools] # runtimes\nnode = \"lts\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	tg := config.Target{Name: "rt", Provider: "tools", File: file}
	if err := New(&sh.Fake{}).Add(tg, provider.Entry{Name: "jq"}); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(file)
	if want := "[tools] # runtimes\nnode = \"lts\"\njq = \"latest\"\n"; string(b) != want {
		t.Fatalf("mise.toml:\n%s", b)
	}
}
