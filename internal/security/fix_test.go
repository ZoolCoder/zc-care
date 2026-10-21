package security

import (
	"strings"
	"testing"
)

func TestLineQuotesWhatTheShellWouldSplit(t *testing.T) {
	got := Line([]string{"sudo", "/bin/sh", "-c", `sed "s/^#auth/auth/" a > b`})
	want := `sudo /bin/sh -c 'sed "s/^#auth/auth/" a > b'`
	if got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
	if got := Line([]string{"defaults", "write", "d", "k", "-string", "Contacts Only"}); !strings.HasSuffix(got, "'Contacts Only'") {
		t.Fatalf("got %s", got)
	}
}

func TestOnlyFixableChecksCarryCommandsAndRootIsNamed(t *testing.T) {
	r := result("firewall", false, "turn it on")
	if len(r.Fix) != 1 || !Root(r.Fix[0]) {
		t.Fatalf("firewall fix %+v", r.Fix)
	}
	if r := result("FileVault", false, "turn it on in System Settings"); len(r.Fix) != 0 {
		t.Fatalf("FileVault must stay advice: %+v", r.Fix)
	}
	if Root([]string{"defaults", "write"}) {
		t.Fatal("defaults is not root")
	}
}
