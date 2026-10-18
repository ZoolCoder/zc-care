package packages

import (
	"context"
	"fmt"
	"strings"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/manifest"
)

// Remove uninstalls kind:name and drops its line from t's manifest. An item
// the manifest does not declare is still uninstalled, so leftovers go through
// the tool too; an App Store app that is not declared is named by its id.
func (p Provider) Remove(ctx context.Context, t config.Target, kind, name string) error {
	if kind == "" {
		kind = "brew"
	}
	data, err := readFile(t.File)
	if err != nil {
		return err
	}
	items, _, err := brew.parse(data)
	if err != nil {
		return fmt.Errorf("%s: %w", t.File, err)
	}
	i := item{Kind: kind, Name: name, ID: name}
	for _, d := range items {
		if d.Kind == kind && strings.EqualFold(d.Name, name) {
			i = d
		}
	}
	if err := brew.remove(p.r, i)(ctx); err != nil {
		return err
	}
	if data, ok := manifest.Drop(data, brew.key, kind+":"+i.Name); ok {
		return writeFile(t.File, data)
	}
	return nil
}
