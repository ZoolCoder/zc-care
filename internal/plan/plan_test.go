package plan

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func noop(context.Context) error { return nil }

func sample() Plan {
	var p Plan
	p.Add(
		Action{Op: OpUpdate, Target: "b", Resource: "x.txt", Detail: "content differs", Do: noop},
		Action{Op: OpDelete, Target: "a", Resource: "old.txt", Detail: "not in the config", Do: noop},
		Action{Op: OpManual, Target: "a", Resource: "secret.txt", Detail: "yours to write"},
	)
	return p
}

func TestWriteIsSortedAndAligned(t *testing.T) {
	var out bytes.Buffer
	if err := sample().Write(&out); err != nil {
		t.Fatal(err)
	}
	want := "DELETE  a  old.txt     not in the config\n" +
		"MANUAL  a  secret.txt  yours to write\n" +
		"UPDATE  b  x.txt       content differs\n" +
		"\n1 of these cannot be automated and are yours to do.\n"
	if out.String() != want {
		t.Fatalf("got\n%s\nwant\n%s", out.String(), want)
	}
	out.Reset()
	_ = Plan{}.Write(&out)
	if !strings.HasPrefix(out.String(), "no changes") {
		t.Fatalf("empty plan: %q", out.String())
	}
}

func TestWriteJSONAndPredicates(t *testing.T) {
	p := sample()
	if !p.Destructive() || len(p.Executable()) != 2 || len(p.Manual()) != 1 || p.Empty() {
		t.Fatal("predicates wrong")
	}
	var out bytes.Buffer
	if err := p.WriteJSON(&out); err != nil {
		t.Fatal(err)
	}
	var got struct {
		Changes, Manual int
		Actions         []JSONAction
	}
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Changes != 2 || got.Manual != 1 || got.Actions[0].Resource != "old.txt" {
		t.Fatalf("json %+v", got)
	}
}

func TestDestructiveCountsOverwritesAndScripts(t *testing.T) {
	var p Plan
	p.Add(Action{Op: OpCreate, Resource: "a", Do: noop}, Action{Op: OpUpdate, Resource: "b", Do: noop})
	if p.Destructive() {
		t.Fatal("create and update are not destructive")
	}
	p.Add(Action{Op: OpUpdate, Resource: "c", Destructive: true, Do: noop})
	if !p.Destructive() {
		t.Fatal("a flagged update is destructive")
	}
	var out bytes.Buffer
	if err := p.WriteJSON(&out); err != nil {
		t.Fatal(err)
	}
	var got struct{ Actions []JSONAction }
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Actions[0].Destructive || got.Actions[1].Destructive || !got.Actions[2].Destructive {
		t.Fatalf("json %+v", got.Actions)
	}
}

func TestSavedMatches(t *testing.T) {
	var buf bytes.Buffer
	if err := sample().Save(&buf, []string{"a"}); err != nil {
		t.Fatal(err)
	}
	saved, err := LoadSaved(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Targets[0] != "a" {
		t.Fatalf("targets %v", saved.Targets)
	}
	if err := saved.Matches(sample()); err != nil {
		t.Fatal(err)
	}
	moved := sample()
	moved.Actions[0].Detail = "content differs again"
	if err := saved.Matches(moved); err == nil || !strings.Contains(err.Error(), "reviewed:") {
		t.Fatalf("moved plan: %v", err)
	}
	if err := saved.Matches(Plan{}); err == nil {
		t.Fatal("empty plan matched")
	}
	if _, err := LoadSaved(strings.NewReader(`{"version":9}`)); err == nil {
		t.Fatal("future version accepted")
	}
	if _, err := LoadSaved(strings.NewReader(savedText(t) + `{"actions":[]}`)); err == nil {
		t.Fatal("a second document after the plan was accepted")
	}
	if _, err := LoadSaved(strings.NewReader(savedText(t) + "\n  ")); err != nil {
		t.Fatalf("trailing space refused: %v", err)
	}
}

func savedText(t *testing.T) string {
	t.Helper()
	var b bytes.Buffer
	if err := sample().Save(&b, []string{"a", "b"}); err != nil {
		t.Fatal(err)
	}
	return b.String()
}

func TestWriteHidesWhatSteersATerminal(t *testing.T) {
	var b bytes.Buffer
	p := Plan{Actions: []Action{{Op: OpUpdate, Target: "t", Resource: "r\u009b2J", Detail: "gnp\u202e.exe\x1b[0m\u200b", Do: noop}}}
	if err := p.Write(&b); err != nil {
		t.Fatal(err)
	}
	if strings.ContainsAny(b.String(), "\u009b\u202e\x1b\u200b") {
		t.Fatalf("plan output %q", b.String())
	}
}

func TestUnsafeCatchesWhatDrawsNothing(t *testing.T) {
	for _, r := range "\u2028\u2029\u034f\u115f\u1160\u17b4\u180b\u3164\uffa0\u2800\ufe0f\U000e0100" {
		if !Unsafe(r) {
			t.Errorf("%U passes", r)
		}
	}
	for _, r := range "aé日🙂\t\n" {
		if Unsafe(r) {
			t.Errorf("%U is refused", r)
		}
	}
}

func TestPlainKeepsOneLineAndCleanKeepsLines(t *testing.T) {
	if got := Plain("a\x1b[2K\nb"); got != "a[2Kb" {
		t.Fatalf("Plain %q", got)
	}
	if got := Clean("a\x1b[2K\nb"); got != "a[2K\nb" {
		t.Fatalf("Clean %q", got)
	}
}

func TestSavedRefusesAChangedDigest(t *testing.T) {
	reviewed := sample()
	reviewed.Actions[0].Digest = "sha256:aaa"
	var buf bytes.Buffer
	if err := reviewed.Save(&buf, nil); err != nil {
		t.Fatal(err)
	}
	saved, err := LoadSaved(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if err := saved.Matches(reviewed); err != nil {
		t.Fatal(err)
	}
	moved := sample()
	moved.Actions[0].Digest = "sha256:bbb"
	err = saved.Matches(moved)
	if err == nil || !strings.Contains(err.Error(), "content of") || strings.Contains(err.Error(), "reviewed:") {
		t.Fatalf("digest-only change: %v", err)
	}
}

func savedWithDigest(t *testing.T, digest string) Saved {
	t.Helper()
	reviewed := sample()
	reviewed.Actions[0].Digest = digest
	var buf bytes.Buffer
	if err := reviewed.Save(&buf, nil); err != nil {
		t.Fatal(err)
	}
	saved, err := LoadSaved(&buf)
	if err != nil {
		t.Fatal(err)
	}
	return saved
}

func TestSavedWithoutADigestIsUnknown(t *testing.T) {
	fresh := sample()
	fresh.Actions[0].Digest = "sha256:aaa"
	err := savedWithDigest(t, "").Matches(fresh)
	if err == nil || !strings.Contains(err.Error(), "saved before content digests existed") {
		t.Fatalf("old plan: %v", err)
	}
}

func TestSavedRefusesWhenTheContentCannotBeRead(t *testing.T) {
	err := savedWithDigest(t, "sha256:aaa").Matches(sample())
	if err == nil || !strings.Contains(err.Error(), "could not be read") {
		t.Fatalf("unreadable: %v", err)
	}
}

func TestSavedWithNoDigestsComparesTheRest(t *testing.T) {
	if err := savedWithDigest(t, "").Matches(sample()); err != nil {
		t.Fatal(err)
	}
}

func TestWriteStripsControlCharacters(t *testing.T) {
	var p Plan
	p.Add(Action{Op: OpUpdate, Target: "t\x1b[2J", Resource: "r\x7f", Detail: "a\tb\x1b]0;owned\x07c\r", Do: noop})
	var out bytes.Buffer
	if err := p.Write(&out); err != nil {
		t.Fatal(err)
	}
	if want := "UPDATE  t[2J  r  a\tb]0;ownedc\n"; out.String() != want {
		t.Fatalf("got %q, want %q", out.String(), want)
	}
	out.Reset()
	if err := p.WriteJSON(&out); err != nil || !strings.Contains(out.String(), `\u001b`) {
		t.Fatalf("json must keep the raw detail: %v %s", err, out.String())
	}
}

func TestDoIsNilExactlyForManual(t *testing.T) {
	for _, bad := range []Action{
		{Op: OpUpdate, Resource: "no-do"},
		{Op: OpManual, Resource: "has-do", Do: noop},
	} {
		var p Plan
		p.Add(bad)
		var out bytes.Buffer
		if err := p.Write(&out); err == nil || !strings.Contains(err.Error(), bad.Resource) {
			t.Errorf("%s: Write accepted it: %v", bad.Resource, err)
		}
		if err := p.WriteJSON(&out); err == nil {
			t.Errorf("%s: WriteJSON accepted it", bad.Resource)
		}
	}
}

func TestMissingProgramIsAWaitingManual(t *testing.T) {
	a := MissingProgram("t", "chezmoi", "install it")
	if a.Op != OpManual || !a.Waiting || a.Do != nil || a.Target != "t" || a.Resource != "chezmoi" || a.Detail != "install it" {
		t.Fatalf("%+v", a)
	}
	if err := a.valid(); err != nil {
		t.Fatal(err)
	}
}

func TestOnlyKeepsTheNamedResources(t *testing.T) {
	p := sample()
	if got := p.Only(nil); len(got.Actions) != 3 {
		t.Fatalf("no filter: %d actions", len(got.Actions))
	}
	got := p.Only([]string{"old.txt", "nothing"})
	if len(got.Actions) != 1 || got.Actions[0].Resource != "old.txt" {
		t.Fatalf("only: %+v", got.Actions)
	}
	if got := p.Only([]string{"nothing"}); !got.Empty() {
		t.Fatalf("unknown resource kept %d actions", len(got.Actions))
	}
}

// Matches compares what a reviewer read: op, target, resource, detail and
// content digest. Destructive and Waiting are derived from those, so a flip
// alone does not make a saved plan stale.
func TestSavedMatchesIgnoresDestructiveAndWaiting(t *testing.T) {
	saved := sample().Snapshot(nil)
	flipped := sample()
	for i := range flipped.Actions {
		flipped.Actions[i].Destructive = !flipped.Actions[i].Destructive
		flipped.Actions[i].Waiting = !flipped.Actions[i].Waiting
	}
	if err := saved.Matches(flipped); err != nil {
		t.Fatalf("flags alone made the plan stale: %v", err)
	}
}
