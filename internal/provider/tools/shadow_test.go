package tools

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/zoolcoder/zc-care/internal/sh"
)

func TestShadowedFindsCommandsRunFromElsewhere(t *testing.T) {
	root := t.TempDir()
	node, java21, java25 := filepath.Join(root, "node", "bin"), filepath.Join(root, "java21", "bin"), filepath.Join(root, "java25", "bin")
	for path, mode := range map[string]os.FileMode{
		filepath.Join(node, "node"): 0o755, filepath.Join(node, "npm"): 0o755, filepath.Join(node, "README"): 0o644,
		filepath.Join(java25, "java"): 0o755, filepath.Join(java21, "java"): 0o755, filepath.Join(java21, "jar"): 0o755,
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, nil, mode); err != nil {
			t.Fatal(err)
		}
	}
	r := &sh.Fake{Out: map[string]string{"mise bin-paths -C dir": node + "\n" + java25 + "\n" + java21 + "\n"}}
	onPath := map[string]string{
		"node": "/opt/homebrew/bin/node",
		"npm":  filepath.Join(root, "mise", "shims", "npm"),
		"java": filepath.Join(java25, "java"),
	}
	lookPath := func(name string) (string, error) {
		if p, ok := onPath[name]; ok {
			return p, nil
		}
		return "", errors.New("not found")
	}
	got, err := Shadowed(context.Background(), r, "dir", lookPath)
	if err != nil {
		t.Fatal(err)
	}
	want := []Shadow{
		{Name: "node", Want: filepath.Join(node, "node"), Got: "/opt/homebrew/bin/node"},
		{Name: "jar", Want: filepath.Join(java21, "jar")},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("shadowed\n got %+v\nwant %+v", got, want)
	}
}
