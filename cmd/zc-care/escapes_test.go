package main

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
)

const evil = "x\x1b]52;c;aGk=\a\u202ey\nforged"

func clean(t *testing.T, what, out string) {
	t.Helper()
	if strings.ContainsFunc(out, plan.Unsafe) {
		t.Fatalf("%s printed %q", what, out)
	}
}

func TestListPrintsNoEscapesAndNoForgedRows(t *testing.T) {
	rows := []engine.TargetItems{
		{Target: "pkgs", Items: []provider.Item{{Name: "a", Desc: evil}}},
		{Target: "broken", Error: evil},
	}
	var out bytes.Buffer
	if err := writeItems(&out, rows, false); err != nil {
		t.Fatal(err)
	}
	clean(t, "list", out.String())
	if strings.Contains(out.String(), "\nforged") {
		t.Fatalf("forged a row: %q", out.String())
	}
}

func TestStatusAndDiffPrintNoEscapes(t *testing.T) {
	var out bytes.Buffer
	if err := writeStatus(&out, []engine.TargetStatus{{Target: "t", Error: evil}}, false); err != nil {
		t.Fatal(err)
	}
	clean(t, "status", out.String())

	out.Reset()
	diffs := []targetDiff{{Target: evil, Errors: []string{evil}, OnlyA: []diffEntry{{Item: evil, A: evil}}}}
	if err := writeDiff(&out, evil, evil, diffs); err != nil {
		t.Fatal(err)
	}
	clean(t, "diff", out.String())
}

func TestHistoryPrintsNoEscapes(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	recordApply("", []engine.Outcome{{Target: "pkgs", Resource: evil}}, evil, io.Discard)
	out, err := run(t, "", "history")
	if err != nil || !strings.Contains(out, "aGk=") {
		t.Fatalf("history %v: %q", err, out)
	}
	clean(t, "history", out)
}

func TestAWordBeforeAFlagIsRefusedNotMoved(t *testing.T) {
	_, err := run(t, "", "plan", "stray", "-yes")
	if err == nil || !strings.Contains(err.Error(), `plan takes no "stray"`) {
		t.Fatalf("err %v", err)
	}
}
