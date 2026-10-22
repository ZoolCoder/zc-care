package dotfiles

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
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
	info, err := os.Lstat(file)
	if errors.Is(err, fs.ErrNotExist) {
		return provider.NewFileUndo(providerName, file), nil
	}
	if err != nil {
		return plan.Undo{}, err
	}
	if info.Mode()&fs.ModeSymlink != 0 {
		target, err := os.Readlink(file)
		if err != nil {
			return plan.Undo{}, err
		}
		return plan.Undo{Provider: providerName, Verb: "symlink", KeepOnError: true,
			Data: map[string]string{"path": file, "target": target}}, nil
	}
	return provider.FileBefore(providerName, file)
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
			a.Do = func(context.Context) error {
				if err := provider.CheckUnchanged(file, u.Data); err != nil {
					return err
				}
				return provider.RemoveFile(file)
			}
		case "symlink":
			a.Detail = "point " + file + " at " + u.Data["target"] + " again"
			a.Do = func(context.Context) error { return restoreLink(file, u.Data["target"]) }
		default:
			a.Detail = "restore the previous content of " + file
			a.Do = func(context.Context) error {
				if err := provider.CheckUnchanged(file, u.Data); err != nil {
					return err
				}
				return provider.RestoreFile(file, u.Data["blob"], u.Data["mode"])
			}
		}
		actions = append(actions, a)
	}
	return actions
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
