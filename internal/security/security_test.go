package security

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/zoolcoder/zc-care/internal/sh"
)

const (
	screenLockCmd  = "/bin/sh -c sysadminctl -screenLock status 2>&1"
	screenSaverCmd = "/bin/sh -c defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null; true"
	guestCmd       = "/bin/sh -c defaults read /Library/Preferences/com.apple.loginwindow GuestEnabled 2>/dev/null; true"
)

// updatesCmd is the line the security updates check runs.
func updatesCmd() string {
	var b strings.Builder
	for _, k := range updateKeys {
		b.WriteString("echo " + k + "=$(defaults read " + softwareUpdate + " " + k + " 2>/dev/null); ")
	}
	return "/bin/sh -c " + strings.TrimSpace(b.String())
}

// secure answers every check as a hardened Mac does.
func secure() map[string]string {
	return map[string]string{
		"fdesetup status":              "FileVault is On.\n",
		firewall + " --getglobalstate": "Firewall is enabled. (State = 1)\n",
		firewall + " --getstealthmode": "Firewall stealth mode is on\n",
		screenLockCmd:                  "sysadminctl[1] screenLock delay is immediate\n",
		screenSaverCmd:                 "300\n",
		"spctl --status":               "assessments enabled\n",
		"csrutil status":               "System Integrity Protection status: enabled.\n",
		"softwareupdate --schedule":    "Automatic checking for updates is turned on\n",
		updatesCmd():                   "CriticalUpdateInstall=1\nConfigDataInstall=1\nAutomaticDownload=1\nAutomaticallyInstallMacOSUpdates=1\n",
		"netstat -an -p tcp":           "tcp4  0  0  127.0.0.1.5432  *.*  LISTEN\ntcp4  0  0  127.0.0.1.22  *.*  LISTEN\ntcp6  0  0  ::1.445  *.*  LISTEN\n",
		"/bin/sh -c defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null; true": "",
		guestCmd: "0\n",
		"/bin/sh -c defaults read com.apple.sharingd DiscoverableMode 2>/dev/null; true": "Contacts Only\n",
		"/bin/sh -c tmutil destinationinfo 2>&1; true":                                   "====\nName          : Backup\nKind          : Local\n",
		"lsof -nP +c 0 -iTCP -sTCP:LISTEN -Fcn":                                          "p1\ncrapportd\nf4\nn*:49152\np2\ncpostgres\nf7\nn127.0.0.1:5432\n",
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

func results(t *testing.T, out map[string]string, pam string) map[string]Result {
	t.Helper()
	got := map[string]Result{}
	for _, r := range checker(t, out, pam).Run(context.Background()) {
		got[r.Name] = r
	}
	return got
}

func TestHardenedMacPasses(t *testing.T) {
	for _, r := range checker(t, secure(), "auth       sufficient     pam_tid.so\n").Run(context.Background()) {
		if !r.OK {
			t.Errorf("%s: %+v", r.Name, r)
		}
	}
}

func TestOpenMacFailsWithFixes(t *testing.T) {
	out := secure()
	// "disabled" contains "enabled"; the check must not read it as on.
	out[firewall+" --getglobalstate"] = "Firewall is disabled. (State = 0)\n"
	out[screenLockCmd] = "sysadminctl[1] screenLock is off\n"
	out[screenSaverCmd] = "0\n"
	out["netstat -an -p tcp"] = "tcp4  0  0  *.445  *.*  LISTEN\ntcp6  0  0  *.22  *.*  LISTEN\n"
	out["/bin/sh -c defaults read com.apple.sharingd DiscoverableMode 2>/dev/null; true"] = "Everyone\n"
	out["/bin/sh -c tmutil destinationinfo 2>&1; true"] = "tmutil: No destinations configured.\n"
	out[guestCmd] = "1\n"
	out["lsof -nP +c 0 -iTCP -sTCP:LISTEN -Fcn"] += "p3\ncnode\nf20\nn*:3000\nf21\nn*:3000\np4\ncGoogle Chrome Helper\nf9\nn*:5353\nf10\nn*:5354\np5\ncssh\nf3\nn*:1\nf4\nn*:2\nf5\nn*:3\nf6\nn*:4\np6\ncControlCenter\nf9\nn*:7000\n"
	delete(out, "csrutil status")
	got := results(t, out, "#auth       sufficient     pam_tid.so\n")
	for _, name := range []string{"firewall", "password after sleep or screen saver", "File Sharing off", "Remote Login off", "AirDrop not open to everyone", "Touch ID for sudo", "Time Machine backups", "Guest account off"} {
		if r := got[name]; r.OK || r.Warn || r.Unknown || r.Detail == "" {
			t.Errorf("%s: %+v, want a failure with a fix", name, r)
		}
	}
	if r := got["screen saver starts within 10 minutes"]; !r.Warn {
		t.Errorf("screen saver never: %+v", r)
	}
	if r := got["System Integrity Protection"]; !r.Unknown || len(r.Fix) != 0 || !strings.HasPrefix(r.Detail, "could not read: ") {
		t.Errorf("SIP with no answer: %+v, want unknown without a fix", r)
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

func TestCommandErrorIsUnknownNotAFailure(t *testing.T) {
	f := &sh.Fake{Out: secure(), Err: map[string]error{"fdesetup status": errors.New("fdesetup: boom")}}
	for _, r := range (Checker{r: f, pam: filepath.Join(t.TempDir(), "none")}).Run(context.Background()) {
		if r.Name != "FileVault disk encryption" {
			continue
		}
		if !r.Unknown || r.OK || r.Warn || len(r.Fix) != 0 || !strings.Contains(r.Detail, "boom") {
			t.Fatalf("%+v", r)
		}
		return
	}
	t.Fatal("no FileVault result")
}

type stuck struct{ sh.Fake }

func (stuck) Output(ctx context.Context, _ string, _ ...string) ([]byte, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}

func TestStuckCommandTimesOut(t *testing.T) {
	_, err := output(context.Background(), &stuck{}, 10*time.Millisecond, "fdesetup", "status")
	if !errors.Is(err, errTimeout) {
		t.Fatalf("err %v, want a timeout", err)
	}
}

func TestCancelledParentIsNotATimeout(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := output(ctx, &stuck{}, time.Minute, "fdesetup", "status")
	if !errors.Is(err, context.Canceled) || errors.Is(err, errTimeout) {
		t.Fatalf("err %v, want context.Canceled", err)
	}
}

func TestListeningIgnoresLoopback(t *testing.T) {
	cases := map[string]bool{
		"tcp4  0  0  *.22  *.*  LISTEN":                          true,
		"tcp46 0  0  *.22  *.*  LISTEN":                          true,
		"tcp4  0  0  192.168.1.5.22  *.*  LISTEN":                true,
		"tcp4  0  0  127.0.0.1.22  *.*  LISTEN":                  false,
		"tcp6  0  0  ::1.22  *.*  LISTEN":                        false,
		"tcp6  0  0  fe80::1%lo0.22  *.*  LISTEN":                false,
		"tcp4  0  0  192.168.1.5.22  10.0.0.2.5000  ESTABLISHED": false,
		"tcp4  0  0  *.222  *.*  LISTEN":                         false,
	}
	for line, want := range cases {
		if got := listens("22")(line); got != want {
			t.Errorf("%q: %v, want %v", line, got, want)
		}
	}
}

// nettopTable is what nettop printed on macOS 27.0.1, cut to its first columns.
const nettopTable = `time,,interface,state,bytes_in,bytes_out
13:51:25.700000,sshd-keygen.123,,,,
13:51:25.727761,tcp4 *:5900<->*:*,,Listen,,,
13:51:25.727831,tcp6 *.22<->*.*,,Listen,,,
13:51:25.727910,tcp4 127.0.0.1:445<->*:*,lo0,Listen,,,
13:51:25.727990,tcp6 ::1.445<->*.*,lo0,Listen,,,
13:51:25.728070,tcp6 fe80::1%lo0.445<->*.*,lo0,Listen,,,
13:51:25.728150,tcp4 192.168.1.5:50000<->192.168.1.9:445,en0,Established,,,
`

const nettopCmd = "nettop -L1 -m tcp -n"

func TestHiddenTableIsReadFromNettop(t *testing.T) {
	out := secure()
	out["netstat -an -p tcp"] = ""
	out[nettopCmd] = nettopTable
	got := results(t, out, "")
	for _, name := range []string{"Remote Login off", "Screen Sharing off"} {
		if r := got[name]; r.OK || r.Unknown {
			t.Errorf("%s: %+v, want a failure", name, r)
		}
	}
	if r := got["File Sharing off"]; !r.OK {
		t.Errorf("a server on loopback only: %+v, want ok", r)
	}
}

func TestTableOfOwnConnectionsIsNotAnAnswer(t *testing.T) {
	out := secure()
	out["netstat -an -p tcp"] = "tcp4  0  0  192.168.1.5.50000  10.0.0.2.443  ESTABLISHED\n"
	out[nettopCmd] = nettopTable
	if r := results(t, out, "")["Remote Login off"]; r.OK || r.Unknown {
		t.Errorf("a server netstat left out: %+v, want a failure", r)
	}
}

// outputCounter counts each command read.
type outputCounter struct {
	*sh.Fake
	reads map[string]int
}

func (c outputCounter) Output(ctx context.Context, name string, args ...string) ([]byte, error) {
	c.reads[sh.Line(name, args...)]++
	return c.Fake.Output(ctx, name, args...)
}

func TestTableIsReadOnce(t *testing.T) {
	out := secure()
	out["netstat -an -p tcp"] = ""
	out[nettopCmd] = nettopTable
	counter := outputCounter{Fake: &sh.Fake{Out: out}, reads: map[string]int{}}
	New(counter).Run(context.Background())
	for _, line := range []string{"netstat -an -p tcp", nettopCmd} {
		if got := counter.reads[line]; got != 1 {
			t.Errorf("%s: read %d times, want once", line, got)
		}
	}
}

func TestHiddenTableNeverPasses(t *testing.T) {
	const sharing = "File Sharing off"
	cases := map[string]func(map[string]string){
		"nettop shows no servers": func(out map[string]string) { out[nettopCmd] = "time,,interface,state\n" },
		"nettop prints nothing":   func(out map[string]string) { out[nettopCmd] = "" },
		"nettop fails":            func(map[string]string) {},
	}
	for name, change := range cases {
		out := secure()
		out["netstat -an -p tcp"] = ""
		change(out)
		if r := results(t, out, "")[sharing]; !r.Unknown || r.OK {
			t.Errorf("%s: %+v, want unknown", name, r)
		}
	}
}

func TestNetstatRows(t *testing.T) {
	want := "tcp4 0 0 *.5900 *.* LISTEN\n" +
		"tcp6 0 0 *.22 *.* LISTEN\n" +
		"tcp4 0 0 127.0.0.1.445 *.* LISTEN\n" +
		"tcp6 0 0 ::1.445 *.* LISTEN\n" +
		"tcp6 0 0 fe80::1%lo0.445 *.* LISTEN\n"
	if got := netstatRows(nettopTable); got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestScreenLockDelays(t *testing.T) {
	cases := map[string]string{
		"screenLock delay is 5 seconds":   "ok",
		"screenLock delay is 60 seconds":  "fail",
		"screenLock is off":               "fail",
		"something else entirely":         "unknown",
		"screenLock delay is immediate":   "ok",
		"screenLock delay is 1 second":    "ok",
		"screenLock delay is 3600 second": "fail",
	}
	for answer, want := range cases {
		out := secure()
		out[screenLockCmd] = answer + "\n"
		r := results(t, out, "")["password after sleep or screen saver"]
		got := map[bool]string{true: "ok"}[r.OK]
		if r.Unknown {
			got = "unknown"
		} else if got == "" {
			got = "fail"
		}
		if got != want {
			t.Errorf("%q: %s, want %s", answer, got, want)
		}
	}
}

func TestScreenSaverIdle(t *testing.T) {
	for idle, warn := range map[string]bool{"": false, "600\n": false, "601\n": true, "0\n": true} {
		out := secure()
		out[screenSaverCmd] = idle
		if r := results(t, out, "")["screen saver starts within 10 minutes"]; r.Warn != warn || r.OK == warn {
			t.Errorf("idleTime %q: %+v", idle, r)
		}
	}
}

func TestSecurityUpdatesReadEachKey(t *testing.T) {
	out := secure()
	out[updatesCmd()] = "CriticalUpdateInstall=\nConfigDataInstall=\nAutomaticDownload=1\nAutomaticallyInstallMacOSUpdates=\n"
	r := results(t, out, "")["security updates install on their own"]
	if !r.OK || !strings.Contains(r.Detail, "CriticalUpdateInstall") {
		t.Errorf("absent keys are on by default: %+v", r)
	}
	out[updatesCmd()] = "CriticalUpdateInstall=1\nConfigDataInstall=0\nAutomaticDownload=\nAutomaticallyInstallMacOSUpdates=0\n"
	r = results(t, out, "")["security updates install on their own"]
	if r.OK || !strings.Contains(r.Detail, "(off: ConfigDataInstall, AutomaticallyInstallMacOSUpdates)") || len(r.Fix) != 0 || !strings.Contains(r.Detail, "restarts") {
		t.Errorf("off keys: %+v", r)
	}
}

func TestGuestAccount(t *testing.T) {
	for answer, ok := range map[string]bool{"": true, "0\n": true, "1\n": false} {
		out := secure()
		out[guestCmd] = answer
		r := results(t, out, "")["Guest account off"]
		if r.OK != ok || (!ok && r.Detail != "sudo sysadminctl -guestAccount off") {
			t.Errorf("GuestEnabled %q: %+v", answer, r)
		}
	}
}

// The app runs a check's sudo fix as root only for these names
// (Fix.rootFixable in app/Sources/ZCCareCore/Fix.swift); a new sudo fix
// must be added there too.
func TestSudoFixesAreTheAppsRootFixable(t *testing.T) {
	out := secure()
	out[firewall+" --getglobalstate"] = "Firewall is disabled.\n"
	out[firewall+" --getstealthmode"] = "Firewall stealth mode is off\n"
	out["spctl --status"] = "assessments disabled\n"
	out["softwareupdate --schedule"] = "Automatic checking for updates is turned off\n"
	out["netstat -an -p tcp"] = "tcp4  0  0  *.445  *.*  LISTEN\n"
	out[guestCmd] = "1\n"
	out["/bin/sh -c defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null; true"] = "me\n"
	out["/bin/sh -c defaults read com.apple.sharingd DiscoverableMode 2>/dev/null; true"] = "Everyone\n"
	out[updatesCmd()] = "CriticalUpdateInstall=0\n"
	want := []string{"File Sharing off", "Gatekeeper", "Guest account off", "Touch ID for sudo", "automatic login off", "automatic update checks", "firewall", "firewall stealth mode"}
	var got []string
	for _, r := range checker(t, out, "").Run(context.Background()) {
		if len(r.Fix) == 0 {
			continue
		}
		got = append(got, r.Name)
		if len(r.Fix) != 1 || !Root(r.Fix[0]) || r.Detail != Line(r.Fix[0]) {
			t.Errorf("%s: fix %+v must be one sudo line and the Detail: %q", r.Name, r.Fix, r.Detail)
		}
	}
	slices.Sort(got)
	if !slices.Equal(got, want) {
		t.Errorf("fixes = %q, want %q", got, want)
	}
	for _, name := range []string{"AirDrop not open to everyone", "security updates install on their own"} {
		if len(fixes[name]) != 0 {
			t.Errorf("%s has advice for Detail, so it has no fix", name)
		}
	}
}

// answering is a command that ran, printed out and failed with err.
type answering struct {
	sh.Fake
	out string
	err error
}

func (a *answering) Output(context.Context, string, ...string) ([]byte, error) {
	return []byte(a.out), a.err
}

// exitStatus is the error of a real command that exited with code.
func exitStatus(t *testing.T, code string) error {
	t.Helper()
	err := exec.Command("/bin/sh", "-c", "exit "+code).Run()
	if err == nil {
		t.Fatal("exit " + code + " did not fail")
	}
	return err
}

func TestGatekeeperReadsTheTextOfAFailedStatus(t *testing.T) {
	failed := exitStatus(t, "1")
	cases := []struct {
		out     string
		err     error
		ok, unk bool
	}{
		{"assessments enabled\n", nil, true, false},
		{"assessments disabled\n", failed, false, false},
		{"assessments disabled\n", nil, false, false},
		{"", failed, false, true},
		{"what?\n", nil, false, true},
	}
	for _, c := range cases {
		r := Checker{r: &answering{out: c.out, err: c.err}}.gatekeeper(context.Background())
		if r.OK != c.ok || r.Unknown != c.unk || (!c.ok && !c.unk && len(r.Fix) != 1) {
			t.Errorf("%q %v: %+v", c.out, c.err, r)
		}
	}
}

func TestExposedNeedsAnAnswerFromLsof(t *testing.T) {
	cases := []struct {
		out  string
		err  error
		want string // ok, warn or unknown
	}{
		{"", exitStatus(t, "1"), "ok"},
		{"", exitStatus(t, "2"), "unknown"},
		{"", errors.New("lsof: not found"), "unknown"},
		{"p1\ncnode\nn192.168.1.5:3000\n", exitStatus(t, "1"), "warn"},
		{"p1\ncnode\nn[fe80::1]:3000\n", nil, "warn"},
		{"p1\ncnode\nn127.0.0.2:3000\nn[::1]:3001\nnlocalhost:3002\nn127.0.0.1:3003\n", nil, "ok"},
		{"p1\ncnode\nn*:3000\n", nil, "warn"},
	}
	for _, c := range cases {
		r := Checker{r: &answering{out: c.out, err: c.err}}.exposed(context.Background())
		got := map[bool]string{true: "ok"}[r.OK]
		switch {
		case r.Unknown:
			got = "unknown"
		case r.Warn:
			got = "warn"
		}
		if got != c.want {
			t.Errorf("%q %v: %s, want %s (%+v)", c.out, c.err, got, c.want, r)
		}
	}
	r := Checker{r: &answering{out: "p1\ncnode\nn192.168.1.5:3000\n"}}.exposed(context.Background())
	if !strings.HasPrefix(r.Detail, "node:3000;") {
		t.Errorf("detail %q", r.Detail)
	}
}

func TestFileSharingFixDisablesAndStops(t *testing.T) {
	line := Line(fixes["File Sharing off"][0])
	for _, part := range []string{"launchctl disable system/com.apple.smbd", "launchctl bootout system/com.apple.smbd"} {
		if !strings.Contains(line, part) {
			t.Errorf("%s lacks %q", line, part)
		}
	}
	login := fixes["automatic login off"][0]
	if !strings.Contains(strings.Join(login, " "), "rm -f /etc/kcpassword") {
		t.Error("automatic login fix leaves /etc/kcpassword")
	}
	if got := fixLine("automatic login off"); !strings.HasPrefix(got, "sudo /bin/sh -c '") || strings.Count(got, "'") != 2 {
		t.Errorf("automatic login line %s", got)
	}
}

func TestTouchIDFixIsOneSingleQuotedSudoLine(t *testing.T) {
	argv := fixes["Touch ID for sudo"][0]
	if strings.Contains(argv[3], "'") {
		t.Fatalf("body has a single quote: %s", argv[3])
	}
	line := Line(argv)
	if !strings.HasPrefix(line, "sudo /bin/sh -c '") || !strings.HasSuffix(line, "'") || strings.Count(line, "'") != 2 {
		t.Fatalf("line %s", line)
	}
}

func TestTouchIDFixKeepsOtherLines(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS sed")
	}
	cases := map[string]string{
		"auth optional pam_reattach.so\n#auth       sufficient     pam_tid.so\n": "auth optional pam_reattach.so\nauth       sufficient     pam_tid.so\n",
		"auth optional pam_reattach.so\n":                                        "auth optional pam_reattach.so\nauth       sufficient     pam_tid.so\n",
		"auth sufficient pam_tid.so\n":                                           "auth sufficient pam_tid.so\n",
		"auth optional pam_tid.so\n":                                             "auth optional pam_tid.so\nauth       sufficient     pam_tid.so\n",
		"#auth optional pam_tid.so\n":                                            "#auth optional pam_tid.so\nauth       sufficient     pam_tid.so\n",
		"":                                                                       "auth       sufficient     pam_tid.so\n",
		"# pam_tid.so enables Touch ID\nauth optional pam_reattach.so\n": "# pam_tid.so enables Touch ID\nauth optional pam_reattach.so\nauth       sufficient     pam_tid.so\n",
		"auth optional pam_reattach.so":                                  "auth optional pam_reattach.so\nauth       sufficient     pam_tid.so\n",
	}
	for before, want := range cases {
		file := filepath.Join(t.TempDir(), "sudo_local")
		if before != "" {
			if err := os.WriteFile(file, []byte(before), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		if out, err := exec.Command("/bin/sh", "-c", touchIDScript(file)).CombinedOutput(); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
		if got, _ := os.ReadFile(file); string(got) != want {
			t.Errorf("from %q got %q, want %q", before, got, want)
		}
	}
}

func TestLoopbackForms(t *testing.T) {
	cases := map[string]bool{
		"::1": true, "::1%lo0": true, "fe80::1%lo0": true, "fe80:1::1": true, "192.168.1.5%lo0": false, "fe80::2%en0": false, "fe80:5::1": false, "127.0.0.1": true, "localhost": true,
		"*": false, "fe80::1%en0": false, "192.168.1.5": false, "10.0.0.2%en0": false,
	}
	for host, want := range cases {
		if got := loopback(host); got != want {
			t.Errorf("%q: %v, want %v", host, got, want)
		}
	}
}

func TestLsofAddressForms(t *testing.T) {
	cases := map[string]bool{
		"[::1]:8080": true, "127.0.0.1:*": true, "localhost:8080": true, "[::1%lo0]:8080": true, "[fe80::1%lo0]:8080": true, "[fe80:1::1]:8080": true,
		"*:8080": false, "[fe80::1%en0]:8080": false,
	}
	for name, want := range cases {
		host, _, ok := lastColon(name)
		if !ok || loopback(strings.Trim(host, "[]")) != want {
			t.Errorf("%q: host %q ok %v, want loopback %v", name, host, ok, want)
		}
	}
}
