package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/engine"
)

const snapshotVersion = 1

// snapshot is what zc-care sees of one Mac: every target's items with their
// live state. It holds paths and hashes, never the content of a file.
type snapshot struct {
	Version int          `json:"version"`
	Host    string       `json:"host"`
	MacOS   string       `json:"macos"`
	Date    string       `json:"date"`
	Targets []snapTarget `json:"targets"`
}

type snapTarget struct {
	Name     string     `json:"name"`
	Provider string     `json:"provider"`
	Items    []snapItem `json:"items"`
	Error    string     `json:"error,omitempty"`
}

// snapItem is one thing a target holds. Version is what is installed, or for
// a setting its live value; Hash is the sha256 of a file's live content.
type snapItem struct {
	Kind    string `json:"kind"`
	Name    string `json:"name"`
	State   string `json:"state"`
	Version string `json:"version,omitempty"`
	Hash    string `json:"hash,omitempty"`
}

func (i snapItem) key() string { return i.Kind + ":" + i.Name }

// present reports whether the machine has the item: a missing, skipped or
// manual one is declared but not there.
func (i snapItem) present() bool {
	return i.State != engine.Missing && i.State != engine.Skipped && i.State != engine.Manual
}

// value is what two machines are compared by: the version, the content hash,
// or when an item has neither, its state.
func (i snapItem) value() string {
	var parts []string
	if i.Version != "" {
		parts = append(parts, i.Version)
	}
	if i.Hash != "" {
		parts = append(parts, "sha256:"+i.Hash[:min(len(i.Hash), 8)])
	}
	if len(parts) == 0 {
		return i.State
	}
	return strings.Join(parts, " ")
}

// newSnapshot turns the engine's inventory into a snapshot. targets are the
// resolved targets the rows came from, so file hashes can be read.
func newSnapshot(rows []engine.TargetItems, targets []config.Target, host, macOS, date string) snapshot {
	byName := map[string]config.Target{}
	for _, t := range targets {
		byName[t.Name] = t
	}
	s := snapshot{Version: snapshotVersion, Host: host, MacOS: macOS, Date: date, Targets: []snapTarget{}}
	for _, r := range rows {
		t := snapTarget{Name: r.Target, Provider: r.Provider, Error: r.Error, Items: []snapItem{}}
		for _, i := range r.Items {
			t.Items = append(t.Items, snapItem{Kind: i.Kind, Name: i.Name, State: i.State,
				Version: i.Version, Hash: liveHash(byName[r.Target], i)})
		}
		t.Items = mergeVersions(t.Items)
		s.Targets = append(s.Targets, t)
	}
	return s
}

// mergeVersions makes an item with several versions, such as a runtime, one
// entry listing them all, so two machines compare by name.
func mergeVersions(items []snapItem) []snapItem {
	var out []snapItem
	at := map[string]int{}
	for _, i := range items {
		n, ok := at[i.key()]
		if !ok {
			at[i.key()] = len(out)
			out = append(out, i)
			continue
		}
		have := &out[n]
		have.Version = joinVersions(have.Version, i.Version)
		if have.State != i.State && i.present() {
			have.State = i.State
		}
	}
	return out
}

func joinVersions(a, b string) string {
	all := slices.DeleteFunc(append(strings.Split(a, ","), strings.Split(b, ",")...), func(v string) bool { return v == "" })
	slices.Sort(all)
	return strings.Join(slices.Compact(all), ",")
}

// liveHash is the sha256 of the file an item stands for on this machine, for
// the providers that manage files; "" for anything else or a file not there.
func liveHash(t config.Target, i engine.Item) string {
	var path string
	switch {
	case t.Provider == "dotfiles" && i.Kind == "dotfile":
		dest := t.Destination
		if dest == "" {
			dest, _ = os.UserHomeDir()
		}
		path = filepath.Join(dest, i.Name)
	case t.Provider == "localdir":
		path = filepath.Join(t.Path, i.Name)
	default:
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// diffEntry is an item on one side only, or on both with different values.
type diffEntry struct {
	Item string `json:"item"`
	A    string `json:"a,omitempty"`
	B    string `json:"b,omitempty"`
}

// targetDiff is what differs in one target.
type targetDiff struct {
	Target    string      `json:"target"`
	OnlyA     []diffEntry `json:"only_in_a,omitempty"`
	OnlyB     []diffEntry `json:"only_in_b,omitempty"`
	Different []diffEntry `json:"different,omitempty"`
	Errors    []string    `json:"errors,omitempty"`
}

func (d targetDiff) empty() bool {
	return len(d.OnlyA)+len(d.OnlyB)+len(d.Different)+len(d.Errors) == 0
}

// diffSnapshots compares two snapshots target by target, in the order a
// lists them and then b's extra targets. Targets that match are left out.
func diffSnapshots(a, b snapshot) []targetDiff {
	var names []string
	index := func(s snapshot) map[string]snapTarget {
		m := map[string]snapTarget{}
		for _, t := range s.Targets {
			m[t.Name] = t
			if !slices.Contains(names, t.Name) {
				names = append(names, t.Name)
			}
		}
		return m
	}
	ta, tb := index(a), index(b)
	var out []targetDiff
	for _, n := range names {
		if d := diffTarget(n, ta[n], tb[n]); !d.empty() {
			out = append(out, d)
		}
	}
	return out
}

func diffTarget(name string, a, b snapTarget) targetDiff {
	d := targetDiff{Target: name}
	if a.Error != "" {
		d.Errors = append(d.Errors, "A: "+a.Error)
	}
	if b.Error != "" {
		d.Errors = append(d.Errors, "B: "+b.Error)
	}
	have := func(t snapTarget) map[string]snapItem {
		m := map[string]snapItem{}
		for _, i := range t.Items {
			if i.present() {
				m[i.key()] = i
			}
		}
		return m
	}
	ia, ib := have(a), have(b)
	for _, k := range sortedKeys(ia, ib) {
		x, inA := ia[k]
		y, inB := ib[k]
		switch {
		case inA && !inB:
			d.OnlyA = append(d.OnlyA, diffEntry{Item: k, A: x.value()})
		case inB && !inA:
			d.OnlyB = append(d.OnlyB, diffEntry{Item: k, B: y.value()})
		case x.value() != y.value():
			d.Different = append(d.Different, diffEntry{Item: k, A: x.value(), B: y.value()})
		}
	}
	return d
}

func sortedKeys(a, b map[string]snapItem) []string {
	seen := map[string]bool{}
	var keys []string
	for _, m := range []map[string]snapItem{a, b} {
		for k := range m {
			if !seen[k] {
				seen[k] = true
				keys = append(keys, k)
			}
		}
	}
	slices.Sort(keys)
	return keys
}

// label names a snapshot's machine for the diff's heading.
func (s snapshot) label(source string) string {
	return fmt.Sprintf("%s: %s, macOS %s, %s", source, s.Host, s.MacOS, s.Date)
}
