package plan

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func FuzzWriteIndented(f *testing.F) {
	for _, seed := range []string{"", "plain", "a\u009bb\u202e", "\U000e0001\x7f", "\"\\\n\t", "\xff\xfe", "\ufe0f\u2028"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, s string) {
		var out bytes.Buffer
		if err := WriteIndented(&out, map[string]string{"s": s}); err != nil {
			t.Fatal(err)
		}
		if i := strings.IndexFunc(out.String(), Unsafe); i >= 0 {
			t.Fatalf("unsafe rune at %d of %q", i, out.String())
		}
		var got map[string]string
		if err := json.Unmarshal(out.Bytes(), &got); err != nil {
			t.Fatalf("%q: %v", out.String(), err)
		}
		// Each invalid byte decodes to U+FFFD, as []rune spells it.
		if want := string([]rune(s)); got["s"] != want {
			t.Fatalf("decoded %q, want %q", got["s"], want)
		}
	})
}

func FuzzLoadSaved(f *testing.F) {
	f.Add(`{"version":1,"targets":["a"],"actions":[]}`)
	f.Add(`{"version":1,"actions":[{"op":"CREATE","target":"a","resource":"r","detail":"d","digest":"x"}]}`)
	f.Add(`{"version":9}`)
	f.Add(`[]`)
	f.Fuzz(func(t *testing.T, s string) {
		saved, err := LoadSaved(strings.NewReader(s))
		if err == nil {
			// One action, so a saved one is compared and not only counted.
			_ = saved.Matches(Plan{Actions: []Action{{Op: OpCreate, Target: "a", Resource: "r", Detail: "d"}}})
		}
	})
}
