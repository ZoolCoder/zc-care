package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/engine"
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
// file only when force is set.
func writeFile(path string, data []byte, force bool) error {
	flags := os.O_WRONLY | os.O_CREATE | os.O_EXCL
	if force {
		flags = os.O_WRONLY | os.O_CREATE | os.O_TRUNC
	}
	f, err := os.OpenFile(path, flags, 0o600)
	if errors.Is(err, os.ErrExist) {
		return fmt.Errorf("%s exists; pass -force to overwrite it", path)
	}
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	return errors.Join(err, f.Close())
}
