package provider

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"

	"github.com/zoolcoder/zc-care/internal/plan"
)

// Digest is a short fingerprint of parts, for plan.Action.Digest. Each part is
// length-prefixed, so two splits of the same bytes differ.
func Digest(parts ...[]byte) string {
	h := sha256.New()
	for _, p := range parts {
		fmt.Fprintf(h, "%d:", len(p))
		h.Write(p)
	}
	return hex.EncodeToString(h.Sum(nil))[:16]
}

// NewFileUndo records that file did not exist before apply wrote it.
func NewFileUndo(providerName, file string) plan.Undo {
	return plan.Undo{Provider: providerName, Verb: "remove", KeepOnError: true, Data: map[string]string{"path": file}}
}

// SavedFileUndo records the content and mode of file before apply replaces
// it. The content is a blob: a config file may hold secrets.
func SavedFileUndo(providerName, file string, content []byte, mode fs.FileMode) plan.Undo {
	return plan.Undo{Provider: providerName, Verb: "restore", KeepOnError: true, Blob: content,
		Data: map[string]string{"path": file, "mode": strconv.FormatUint(uint64(mode.Perm()), 8)}}
}

// FileBefore records the plain file at file, or that it is missing. A symlink
// is followed, so the record names the file a write would change.
func FileBefore(providerName, file string) (plan.Undo, error) {
	if real, err := filepath.EvalSymlinks(file); err == nil {
		file = real
	}
	info, err := os.Stat(file)
	if errors.Is(err, fs.ErrNotExist) {
		return NewFileUndo(providerName, file), nil
	}
	if err != nil {
		return plan.Undo{}, err
	}
	if !info.Mode().IsRegular() {
		return plan.Irreversible(file + " is not a regular file"), nil
	}
	content, err := os.ReadFile(file)
	if err != nil {
		return plan.Undo{}, err
	}
	return SavedFileUndo(providerName, file, content, info.Mode()), nil
}

// RevertFiles turns the records FileBefore, NewFileUndo and SavedFileUndo made
// into actions. Both verbs lose what is there now, so both are destructive.
func RevertFiles(undos []plan.Undo) []plan.Action {
	actions := make([]plan.Action, 0, len(undos))
	for _, u := range undos {
		a := plan.Action{Op: plan.OpUpdate, Target: u.Target, Resource: u.Resource, Destructive: true}
		file := u.Data["path"]
		if u.Verb == "remove" {
			a.Op, a.Detail = plan.OpDelete, "remove "+file+": it did not exist before"
			a.Do = func(context.Context) error { return RemoveFile(file) }
		} else {
			a.Detail = "restore the previous content of " + file
			a.Do = func(context.Context) error { return RestoreFile(file, u.Data["blob"], u.Data["mode"]) }
		}
		actions = append(actions, a)
	}
	return actions
}

// RemoveFile removes file; a file already gone is fine.
func RemoveFile(file string) error {
	if err := os.Remove(file); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

// RestoreFile writes the content kept in blob over file, through a temporary
// file so a failure leaves the current file whole.
func RestoreFile(file, blob, mode string) error {
	data, err := os.ReadFile(blob)
	if err != nil {
		return fmt.Errorf("the saved copy is gone: %w", err)
	}
	perm, err := strconv.ParseUint(mode, 8, 32)
	if err != nil {
		return fmt.Errorf("saved mode %q: %w", mode, err)
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(file), ".zc-care-undo-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	_, werr := tmp.Write(data)
	if err := errors.Join(werr, tmp.Chmod(fs.FileMode(perm)), tmp.Close()); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), file)
}
