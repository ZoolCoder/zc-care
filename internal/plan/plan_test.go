package plan

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func sample() Plan {
	var p Plan
	p.Add(
		Action{Op: OpUpdate, Target: "b", Resource: "x.txt", Detail: "content differs"},
		Action{Op: OpDelete, Target: "a", Resource: "old.txt", Detail: "not in the config"},
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
	p.Add(Action{Op: OpCreate, Resource: "a"}, Action{Op: OpUpdate, Resource: "b"})
	if p.Destructive() {
		t.Fatal("create and update are not destructive")
	}
	p.Add(Action{Op: OpUpdate, Resource: "c", Destructive: true})
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
