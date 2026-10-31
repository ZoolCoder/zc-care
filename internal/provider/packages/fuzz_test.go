package packages

import "testing"

func FuzzParseBrewfile(f *testing.F) {
	f.Add([]byte("brew \"tmux\"\ncask \"ghostty\"\nmas \"Xcode\", id: 497799835\n"))
	f.Add([]byte("tap \"user/tap\" # why\n# section\n"))
	f.Add([]byte("brew '"))
	f.Fuzz(func(t *testing.T, data []byte) { _, _, _ = parseBrewfile(data) })
}
