package security

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/sh"
)

// secure answers every check as a hardened Mac does.
func secure() map[string]string {
	return map[string]string{
		"fdesetup status":                                "FileVault is On.\n",
		firewall + " --getglobalstate":                   "Firewall is enabled. (State = 1)\n",
		firewall + " --getstealthmode":                   "Firewall stealth mode is on\n",
		"/bin/sh -c sysadminctl -screenLock status 2>&1": "sysadminctl[1] screenLock delay is immediate\n",
		"spctl --status":                                 "assessments enabled\n",
		"csrutil status":                                 "System Integrity Protection status: enabled.\n",
		"softwareupdate --schedule":                      "Automatic checking for updates is turned on\n",
		"/bin/sh -c defaults read /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall; defaults read /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall": "1\n1\n",
		"netstat -an -p tcp": "tcp4  0  0  127.0.0.1.5432  *.*  LISTEN\n",
		"/bin/sh -c defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null; true": "",
		"/bin/sh -c defaults read com.apple.sharingd DiscoverableMode 2>/dev/null; true":                      "Contacts Only\n",
		"/bin/sh -c tmutil destinationinfo 2>&1; true":                                                        "====\nName          : Backup\nKind          : Local\n",
		"lsof -nP +c 0 -iTCP -sTCP:LISTEN -Fcn":                                                               "p1\ncrapportd\nf4\nn*:49152\np2\ncpostgres\nf7\nn127.0.0.1:5432\n",
	}
}

func checker(t *testing.T, out map[string]string, pam string) Checker {
	t.Helper()
	path := filepath.Join(t.TempDir(), "sudo_local")
	if err := os.WriteFile(path, []byte(pam), 0o600); err != nil {
		t.Fatal(err)
	}
	return Checker{r: &sh.Fake{Out: out}, pam: path}
}

func TestHardenedMacPasses(t *testing.T) {
	for _, r := range checker(t, secure(), "auth       sufficient     pam_tid.so\n").Run(context.Background()) {
		if !r.OK {
			t.Errorf("%s: %s", r.Name, r.Detail)
		}
	}
}

func TestOpenMacFailsWithFixes(t *testing.T) {
	out := secure()
	// "disabled" contains "enabled"; the check must not read it as on.
	out[firewall+" --getglobalstate"] = "Firewall is disabled. (State = 0)\n"
	out["/bin/sh -c sysadminctl -screenLock status 2>&1"] = "sysadminctl[1] screenLock is off\n"
	out["netstat -an -p tcp"] = "tcp4  0  0  *.445  *.*  LISTEN\ntcp6  0  0  *.22  *.*  LISTEN\n"
	out["/bin/sh -c defaults read com.apple.sharingd DiscoverableMode 2>/dev/null; true"] = "Everyone\n"
	out["/bin/sh -c tmutil destinationinfo 2>&1; true"] = "tmutil: No destinations configured.\n"
	out["lsof -nP +c 0 -iTCP -sTCP:LISTEN -Fcn"] += "p3\ncnode\nf20\nn*:3000\nf21\nn*:3000\np4\ncGoogle Chrome Helper\nf9\nn*:5353\nf10\nn*:5354\np5\ncssh\nf3\nn*:1\nf4\nn*:2\nf5\nn*:3\nf6\nn*:4\np6\ncControlCenter\nf9\nn*:7000\n"
	delete(out, "csrutil status")
	got := map[string]Result{}
	for _, r := range checker(t, out, "#auth       sufficient     pam_tid.so\n").Run(context.Background()) {
		got[r.Name] = r
	}
	for _, name := range []string{"firewall", "password after sleep or screen saver", "File Sharing off", "Remote Login off", "AirDrop not open to everyone", "System Integrity Protection", "Touch ID for sudo", "Time Machine backups"} {
		if r := got[name]; r.OK || r.Warn || r.Detail == "" {
			t.Errorf("%s: %+v, want a failure with a fix", name, r)
		}
	}
	if r := got["servers on every network interface"]; !r.Warn || r.Detail != "node:3000 Google Chrome Helper:5353,5354 ssh on 4 ports AirPlay Receiver:7000; "+
		"bind dev servers to 127.0.0.1, and turn off AirPlay Receiver in System Settings > General > AirDrop & Handoff" {
		t.Errorf("exposed: %+v", r)
	}
	if !got["Screen Sharing off"].OK || !got["automatic login off"].OK {
		t.Error("Screen Sharing and automatic login should still pass")
	}
	if !got["FileVault disk encryption"].OK {
		t.Error("FileVault should still pass")
	}
}

// The app runs a check's sudo fix as root only for these names
// (Fix.rootFixable in app/Sources/ZCCareCore/Fix.swift); a new sudo fix
// must be added there too.
func TestSudoFixesAreTheAppsRootFixable(t *testing.T) {
	want := []string{"firewall", "firewall stealth mode", "Gatekeeper", "automatic update checks", "File Sharing off", "Touch ID for sudo"}
	var got []string
	for _, r := range checker(t, map[string]string{}, "").Run(context.Background()) {
		if strings.Contains(r.Detail, "sudo ") && r.Name != "servers on every network interface" {
			got = append(got, r.Name)
		}
	}
	if !slices.Equal(got, want) {
		t.Errorf("sudo fixes = %q, want %q", got, want)
	}
}
