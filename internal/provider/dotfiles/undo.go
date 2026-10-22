package dotfiles

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"

	"github.com/zoolcoder/zc-care/internal/plan"
)

const providerName = "dotfiles"

// before records the file apply is about to write: its content, kept as a
// blob because a dotfile may hold secrets, and its mode; or the target of a
// symlink; or that it does not exist yet. chezmoi may fail after it changed
// the file, so the record is kept on failure too.
func before(file string, script bool) (plan.Undo, error) {
	if script {
		return plan.Irreversible("a script's effects are not recorded"), nil
	}
	u := plan.Undo{Provider: providerName, KeepOnError: true, Data: map[string]string{"path": file}}
	info, err := os.Lstat(file)
	if errors.Is(err, fs.ErrNotExist) {
		u.Verb = "remove"
		return u, nil
	}
	if err != nil {
		return plan.Undo{}, err
	}
	if info.Mode()&fs.ModeSymlink != 0 {
		if u.Data["target"], err = os.Readlink(file); err != nil {
			return plan.Undo{}, err
		}
		u.Verb = "symlink"
		return u, nil
	}
	if !info.Mode().IsRegular() {
		return plan.Irreversible(file + " is not a regular file"), nil
	}
	if u.Blob, err = os.ReadFile(file); err != nil {
		return plan.Undo{}, err
	}
	u.Verb = "restore"
	u.Data["mode"] = strconv.FormatUint(uint64(info.Mode().Perm()), 8)
	return u, nil
}

// Revert puts each file back as it was before apply wrote it, or removes a
// file that apply created. Both lose what is there now, so a restore is
// destructive too.
func (Provider) Revert(undos []plan.Undo) []plan.Action {
	actions := make([]plan.Action, 0, len(undos))
	for _, u := range undos {
		a := plan.Action{Op: plan.OpUpdate, Target: u.Target, Resource: u.Resource, Destructive: true}
		file := u.Data["path"]
		switch u.Verb {
		case "remove":
			a.Op, a.Detail = plan.OpDelete, "remove "+file+": it did not exist before"
			a.Do = func(context.Context) error { return removeFile(file) }
		case "symlink":
			a.Detail = "point " + file + " at " + u.Data["target"] + " again"
			a.Do = func(context.Context) error { return restoreLink(file, u.Data["target"]) }
		default:
			a.Detail = "restore the previous content of " + file
			a.Do = func(context.Context) error { return restoreFile(file, u.Data["blob"], u.Data["mode"]) }
		}
		actions = append(actions, a)
	}
	return actions
}

func removeFile(file string) error {
	if err := os.Remove(file); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

// restoreLink makes file a symlink to target, replacing what is there in one
// rename.
func restoreLink(file, target string) error {
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	tmp := filepath.Join(filepath.Dir(file), fmt.Sprintf(".zc-care-undo-%d", os.Getpid()))
	_ = os.Remove(tmp)
	if err := os.Symlink(target, tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, file); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// restoreFile writes the content kept in blob over file, through a temporary
// file so a failure leaves the current file whole.
func restoreFile(file, blob, mode string) error {
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
