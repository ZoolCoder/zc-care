package packages

import (
	"bytes"
	"context"
	"errors"
	"fmt"

	"github.com/zoolcoder/zc-care/internal/config"
)

// Capture writes a manifest of what this machine has installed on purpose,
// as a Brewfile.
func (p Provider) Capture(ctx context.Context, _ config.Target) ([]byte, error) {
	if !p.r.Has(brew.program) {
		return nil, errMissing{name: "brew", program: brew.program}
	}
	chosen, err := brew.chosen(ctx, p.r)
	if err != nil {
		return nil, err
	}
	if len(chosen) == 0 {
		return nil, errors.New("nothing installed on purpose was found")
	}
	var b bytes.Buffer
	fmt.Fprintf(&b, "# Captured by zc-care from what this machine has installed.\n")
	for _, i := range chosen {
		if i.Kind == "mas" {
			fmt.Fprintf(&b, "mas %q, id: %s\n", i.Name, i.ID)
		} else {
			fmt.Fprintf(&b, "%s %q\n", i.Kind, i.Name)
		}
	}
	return b.Bytes(), nil
}
