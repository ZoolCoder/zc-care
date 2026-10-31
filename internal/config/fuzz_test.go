package config

import "testing"

func FuzzParse(f *testing.F) {
	f.Add([]byte("version: 1\ntargets:\n  - name: a\n    provider: localdir\n    path: /tmp/x\n"))
	f.Add([]byte("version: 1\nsecrets: {}\n"))
	f.Add([]byte("a: &x [*x]\n"))
	f.Add([]byte(""))
	f.Fuzz(func(t *testing.T, data []byte) { _, _ = Parse(data) })
}
