// Package localdir is the example provider: a target is a directory, and the
// config declares the files it should hold. All file access goes through
// os.Root, so a symlink inside the directory cannot lead a write outside it.
package localdir

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
)

type Provider struct{}

func New() Provider { return Provider{} }

// Plan lists a CREATE for each declared file that is missing, an UPDATE for
// each whose content differs, and with prune a DELETE for each file the config
// does not declare.
func (Provider) Plan(_ context.Context, t config.Target) ([]plan.Action, error) {
	live, err := read(t.Path)
	if err != nil {
		return nil, err
	}
	var actions []plan.Action
	for _, name := range slices.Sorted(maps.Keys(t.Files)) {
		want := []byte(t.Files[name])
		have, exists := live[name]
		switch {
		case !exists:
			actions = append(actions, write(t, name, want, plan.OpCreate, fmt.Sprintf("new file, %d bytes", len(want))))
		case !bytes.Equal(have, want):
			actions = append(actions, write(t, name, want, plan.OpUpdate,
				fmt.Sprintf("content differs, %d to %d bytes", len(have), len(want))))
		}
	}
	if t.Prune {
		for _, name := range slices.Sorted(maps.Keys(live)) {
			if _, declared := t.Files[name]; !declared {
				actions = append(actions, remove(t, name))
			}
		}
	}
	return actions, nil
}

// Measure counts the declared files that are in place.
func (Provider) Measure(_ context.Context, t config.Target) (provider.Live, error) {
	live, err := read(t.Path)
	if err != nil {
		return provider.Live{}, err
	}
	m := provider.Live{Declared: len(t.Files)}
	for name, want := range t.Files {
		if have, ok := live[name]; ok && string(have) == want {
			m.InPlace++
		}
	}
	m.Summary = fmt.Sprintf("%d of %d declared files in place, %d on disk", m.InPlace, m.Declared, len(live))
	return m, nil
}

// Items lists each declared file and whether its content is in place.
func (Provider) Items(_ context.Context, t config.Target) ([]provider.Item, error) {
	live, err := read(t.Path)
	if err != nil {
		return nil, err
	}
	items := make([]provider.Item, 0, len(t.Files))
	for _, name := range slices.Sorted(maps.Keys(t.Files)) {
		item := provider.Item{Name: name, Kind: "file", State: provider.InPlace}
		if have, ok := live[name]; !ok {
			item.State = provider.Missing
		} else if string(have) != t.Files[name] {
			item.State = provider.Differs
		}
		items = append(items, item)
	}
	return items, nil
}

// read returns every regular file under dir, by slash path. A directory that
// does not exist yet is empty, not an error: the first apply creates it.
func read(dir string) (map[string][]byte, error) {
	files := map[string][]byte{}
	root, err := os.OpenRoot(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return files, nil
	}
	if err != nil {
		return nil, err
	}
	defer func() { _ = root.Close() }()
	err = fs.WalkDir(root.FS(), ".", func(name string, d fs.DirEntry, err error) error {
		if err != nil || !d.Type().IsRegular() {
			return err
		}
		b, err := root.ReadFile(name)
		files[name] = b
		return err
	})
	return files, err
}

func write(t config.Target, name string, content []byte, op plan.Op, detail string) plan.Action {
	return plan.Action{Op: op, Target: t.Name, Resource: name, Detail: detail,
		Do: func(context.Context) error {
			if err := os.MkdirAll(t.Path, 0o755); err != nil {
				return err
			}
			root, err := os.OpenRoot(t.Path)
			if err != nil {
				return err
			}
			defer func() { _ = root.Close() }()
			if err := root.MkdirAll(filepath.Dir(name), 0o755); err != nil {
				return err
			}
			return root.WriteFile(name, content, 0o644)
		}}
}

func remove(t config.Target, name string) plan.Action {
	return plan.Action{Op: plan.OpDelete, Target: t.Name, Resource: name, Detail: "not in the config",
		Do: func(context.Context) error {
			root, err := os.OpenRoot(t.Path)
			if err != nil {
				return err
			}
			defer func() { _ = root.Close() }()
			if err := root.Remove(name); err != nil && !errors.Is(err, fs.ErrNotExist) {
				return err
			}
			return nil
		}}
}
