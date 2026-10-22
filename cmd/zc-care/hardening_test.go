package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/plan"
)

func TestFlagsBeforeTheSubcommandAreRejected(t *testing.T) {
	cfg, dir := fixture(t)
	for _, args := range [][]string{
		{"-target", "notes", "apply", "-config", cfg},
		{"-yes", "apply", "-config", cfg},
	} {
		_, err := run(t, "", args...)
		if err == nil || !strings.Contains(err.Error(), "put flags after the subcommand: zc-care apply") {
			t.Fatalf("%v: %v", args, err)
		}
	}
	if _, err := os.Stat(dir); err == nil {
		t.Fatal("something was applied")
	}
	_, err := run(t, "", "-target", "notes", "apply")
	if want := "zc-care apply -target notes"; err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("err %v, want %q", err, want)
	}
	if _, err := run(t, "", "-config", cfg); err != nil {
		t.Fatalf("plain plan with flags first: %v", err)
	}
}

func TestFlagsAfterTheOperandAreRejected(t *testing.T) {
	_, err := run(t, "", "remove", "brew:htop", "-yes")
	if err == nil || !strings.Contains(err.Error(), "flags go before NAME: zc-care remove -yes brew:htop") {
		t.Fatalf("remove: %v", err)
	}
	_, err = run(t, "", "add", "brew:htop", "-why", "x")
	if err == nil || !strings.Contains(err.Error(), "flags go before NAME: zc-care add") {
		t.Fatalf("add: %v", err)
	}
}

func TestLostUndoRecordIsWarnedAbout(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can write anywhere")
	}
	data := t.TempDir()
	if err := os.Chmod(data, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(data, 0o700) })
	undo := plan.Undo{Provider: "p", Verb: "remove", Data: map[string]string{"path": "x"}}
	var stderr bytes.Buffer
	recordApply(data, []engine.Outcome{{Target: "t", Resource: "r", Undo: &undo}}, "the terminal", &stderr)
	for _, want := range []string{"warning: undo record not saved:", "warning: activity log not written:"} {
		if !strings.Contains(stderr.String(), want) {
			t.Errorf("stderr lacks %q:\n%s", want, stderr.String())
		}
	}
}

func TestJournalStampsFileUndosAndSurvivesABlobWithoutData(t *testing.T) {
	data, file := t.TempDir(), filepath.Join(t.TempDir(), "conf")
	if err := os.WriteFile(file, []byte("applied"), 0o600); err != nil {
		t.Fatal(err)
	}
	stamped := plan.Undo{Provider: "localdir", Verb: "remove", Data: map[string]string{"path": file}}
	bare := plan.Undo{Provider: "p", Verb: "restore", Blob: []byte("old")}
	err := saveJournal(data, []engine.Outcome{
		{Target: "t", Resource: "a", Undo: &stamped},
		{Target: "t", Resource: "b", Undo: &bare},
	}, "apply")
	if err != nil {
		t.Fatal(err)
	}
	entries, err := loadJournal(data, io.Discard)
	if err != nil || len(entries) != 1 || len(entries[0].Undos) != 2 {
		t.Fatalf("entries %v: %+v", err, entries)
	}
	if entries[0].Undos[0].Data["digest"] == "" {
		t.Error("no digest stamped")
	}
	if entries[0].Undos[1].Data["blob"] == "" {
		t.Error("blob path lost")
	}
	info, err := os.Stat(filepath.Join(journalDir(data), entries[0].ID+".json"))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("entry file %v %v", info, err)
	}
}

func TestCancelledApplyJSONSaysSo(t *testing.T) {
	cfg, dir := fixture(t)
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "stray.txt"), []byte("x"), 0o600)
	var out, errOut bytes.Buffer
	err := runCLI([]string{"apply", "-json", "-config", cfg}, strings.NewReader(""), &out, &errOut)
	if !errors.Is(err, errCancelled) {
		t.Fatalf("err %v", err)
	}
	var got applyResult
	if jerr := json.Unmarshal(out.Bytes(), &got); jerr != nil || !got.Cancelled || got.Verified || len(got.Applied) != 0 {
		t.Fatalf("result %v: %s", jerr, out.String())
	}
}

func TestDiffUsesTheConfigTheSnapshotWasTakenFrom(t *testing.T) {
	cfg, _ := fixture(t)
	if _, err := run(t, "", "apply", "-config", cfg); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "mac.json")
	if _, err := run(t, "", "export", "-config", cfg, "-o", file); err != nil {
		t.Fatal(err)
	}
	t.Chdir(t.TempDir())
	t.Setenv(envConfig, filepath.Join(t.TempDir(), "other.yaml"))
	if out, err := run(t, "", "diff", file); err != nil || !strings.Contains(out, "no differences") || strings.Contains(out, "warning") {
		t.Fatalf("diff %v:\n%s", err, out)
	}

	other, _ := fixture(t)
	out, _ := run(t, "", "diff", "-config", other, file)
	if !strings.Contains(out, "warning: snapshot was taken from "+absConfig(cfg)) {
		t.Fatalf("no warning:\n%s", out)
	}
}
