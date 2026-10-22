package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/manifest"
)

// runCapture writes the selected target's manifest from what this machine
// has: to stdout, or to out. It never overwrites a file unless forced, and it
// never writes the target's own manifest by default, so a capture is
// reviewed before it replaces anything.
func runCapture(ctx context.Context, eng *engine.Engine, out string, force bool, stdout io.Writer) error {
	t, data, err := eng.Capture(ctx)
	if err != nil {
		return err
	}
	return writeCapture(t, data, out, force, stdout)
}

func writeCapture(t config.Target, data []byte, out string, force bool, stdout io.Writer) error {
	if out == "" {
		_, err := stdout.Write(data)
		return err
	}
	if err := writeFile(out, data, force); err != nil {
		return err
	}
	_, err := fmt.Fprintf(stdout, "captured %s to %s\n", t.Name, out)
	return err
}

// writeFile saves data to path with mode 0600, which a manifest or snapshot
// naming every package and file on the Mac deserves. It replaces an existing
// file only when force is set, and then through a temp file and a rename, so
// the mode is 0600 whatever the old file had and a failure leaves it intact.
func writeFile(path string, data []byte, force bool) error {
	if force {
		return manifest.WriteFile(path, data, 0o600)
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		return fmt.Errorf("%s exists; pass -force to overwrite it", path)
	}
	if err != nil {
		return err
	}
	if _, err = f.Write(data); err != nil {
		_ = f.Close()
		_ = os.Remove(path)
		return err
	}
	return f.Close()
}
