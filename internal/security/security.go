// Package security checks that a lost or unlocked Mac does not expose code,
// keys and sessions: disk encryption, the firewall, the screen lock, system
// protections, updates, and servers reachable from the network. It only
// reads; each failed check says how to fix it.
package security

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/zoolcoder/zc-care/internal/sh"
)

// Result is one check: ok, or the fix.
type Result struct {
	Name   string
	OK     bool
	Detail string
	// Warn marks a finding to look at rather than a failure.
	Warn bool
	// Unknown marks a check that could not read its answer; Detail says why.
	// It is neither a pass nor a failure, and it never carries a fix.
	Unknown bool
	// Fix is the commands that repair a failed check, when commands can; the
	// rest stay advice in Detail.
	Fix [][]string
}

const (
	firewall       = "/usr/libexec/ApplicationFirewall/socketfilterfw"
	softwareUpdate = "/Library/Preferences/com.apple.SoftwareUpdate"

	readTimeout = 10 * time.Second
)

type check struct {
	name, fix string
	cmd       []string
	pass      func(out string) bool
}

func contains(s string) func(string) bool {
	return func(out string) bool { return strings.Contains(out, s) }
}

// listens reports whether netstat output shows a TCP server on port that
// another machine can reach: a wildcard or LAN address, not loopback.
func listens(port string) func(string) bool {
	return func(out string) bool {
		for _, line := range strings.Split(out, "\n") {
			f := strings.Fields(line)
			if len(f) < 6 || !strings.HasPrefix(f[0], "tcp") || f[len(f)-1] != "LISTEN" {
				continue
			}
			addr, ok := strings.CutSuffix(f[3], "."+port)
			if ok && !loopback(addr) {
				return true
			}
		}
		return false
	}
}

// loopback is an address only this machine can reach.
func loopback(host string) bool {
	host, _, _ = strings.Cut(host, "%")
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	return host == "localhost"
}

func not(f func(string) bool) func(string) bool {
	return func(out string) bool { return !f(out) }
}

var netstat = []string{"netstat", "-an", "-p", "tcp"}

var checks = []check{
	{"FileVault disk encryption", "turn FileVault on in System Settings, Privacy & Security",
		[]string{"fdesetup", "status"}, contains("FileVault is On")},
	{"firewall", "sudo " + firewall + " --setglobalstate on",
		[]string{firewall, "--getglobalstate"}, contains("is enabled")},
	{"firewall stealth mode", "sudo " + firewall + " --setstealthmode on",
		[]string{firewall, "--getstealthmode"}, contains("mode is on")},
	{"System Integrity Protection", "start up in Recovery and run csrutil enable",
		[]string{"csrutil", "status"}, contains("status: enabled")},
	{"automatic update checks", "sudo softwareupdate --schedule on",
		[]string{"softwareupdate", "--schedule"}, contains("turned on")},
	{"File Sharing off", fixLine("File Sharing off"), netstat, not(listens("445"))},
	{"Remote Login off", "System Settings, General, Sharing: turn Remote Login off, or limit it to your user",
		netstat, not(listens("22"))},
	{"Screen Sharing off", "System Settings, General, Sharing: turn Screen Sharing and Remote Management off",
		netstat, not(listens("5900"))},
	// Each reads a key that is absent on a safe Mac, so the shell forgives
	// the error and an empty answer passes.
	{"automatic login off", fixLine("automatic login off"),
		[]string{"/bin/sh", "-c", "defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null; true"},
		func(out string) bool { return strings.TrimSpace(out) == "" }},
	{"Guest account off", fixLine("Guest account off"),
		[]string{"/bin/sh", "-c", "defaults read /Library/Preferences/com.apple.loginwindow GuestEnabled 2>/dev/null; true"},
		func(out string) bool { return slices.Contains([]string{"", "0"}, strings.TrimSpace(out)) }},
	// A Mac without a backup disk says so on standard error.
	{"Time Machine backups", "System Settings, General, Time Machine: add a backup disk",
		[]string{"/bin/sh", "-c", "tmutil destinationinfo 2>&1; true"},
		func(out string) bool { return strings.Contains(out, "Name") }},
	{"AirDrop not open to everyone", "System Settings, General, AirDrop & Handoff: set AirDrop to Contacts Only",
		[]string{"/bin/sh", "-c", "defaults read com.apple.sharingd DiscoverableMode 2>/dev/null; true"},
		func(out string) bool { return !strings.Contains(out, "Everyone") }},
}

// touchID is the line sudo_local.template ships commented out.
var touchID = regexp.MustCompile(`(?m)^auth\s+sufficient\s+pam_tid\.so`)

// Checker runs the checks through r; pam is the sudo PAM file that enables
// Touch ID.
type Checker struct {
	r   sh.Runner
	pam string
}

func New(r sh.Runner) Checker { return Checker{r: r, pam: "/etc/pam.d/sudo_local"} }

// Run runs every check, in a fixed order. A check that cannot read its
// answer is Unknown, not a failure.
func (c Checker) Run(ctx context.Context) []Result {
	var results []Result
	for _, ch := range checks {
		out, err := output(ctx, c.r, readTimeout, ch.cmd...)
		if err != nil {
			results = append(results, unknown(ch.name, err))
			continue
		}
		results = append(results, result(ch.name, ch.pass(out), ch.fix))
	}
	results = append(results, c.gatekeeper(ctx))
	results = append(results, c.screenLock(ctx)...)
	results = append(results, c.securityUpdates(ctx))
	pam, _ := os.ReadFile(c.pam)
	results = append(results, result("Touch ID for sudo", touchID.Match(pam), fixLine("Touch ID for sudo")))
	return append(results, c.exposed(ctx))
}

var errTimeout = errors.New("timed out")

// output runs a command with a time limit, so one stuck tool cannot hang
// the report. The error carries the command's standard error.
func output(ctx context.Context, r sh.Runner, limit time.Duration, argv ...string) (string, error) {
	parent := ctx
	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	out, err := r.Output(ctx, argv[0], argv[1:]...)
	if err != nil && parent.Err() != nil {
		return string(out), parent.Err()
	}
	if err != nil && errors.Is(ctx.Err(), context.DeadlineExceeded) {
		err = fmt.Errorf("%s: %w after %s", sh.Line(argv[0], argv[1:]...), errTimeout, limit)
	}
	return string(out), err
}

// exitCode is the status of a command that ran and failed, or -1.
func exitCode(err error) int {
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return exit.ExitCode()
	}
	return -1
}

func unknown(name string, err error) Result {
	return Result{Name: name, Unknown: true, Detail: "could not read: " + err.Error()}
}

func result(name string, ok bool, fix string) Result {
	if ok {
		return Result{Name: name, OK: true}
	}
	return Result{Name: name, Detail: fix, Fix: fixes[name]}
}

// gatekeeper reads spctl, which exits non-zero when assessments are off, so
// the answer is the text, not the status.
func (c Checker) gatekeeper(ctx context.Context) Result {
	const name = "Gatekeeper"
	out, err := output(ctx, c.r, readTimeout, "spctl", "--status")
	switch {
	case strings.Contains(out, "assessments enabled"):
		return Result{Name: name, OK: true}
	case strings.Contains(out, "assessments disabled"):
		return result(name, false, fixLine(name))
	case err != nil:
		return unknown(name, err)
	}
	return unknown(name, fmt.Errorf("unexpected answer %q", strings.TrimSpace(out)))
}

var lockDelay = regexp.MustCompile(`delay is (\d+) second`)

// screenLock checks that a password is asked at once or within 5 seconds of
// sleep or the screen saver, then the screen saver's own delay.
func (c Checker) screenLock(ctx context.Context) []Result {
	const name = "password after sleep or screen saver"
	const advice = "System Settings, Lock Screen: require a password immediately"
	// sysadminctl prints its answer to standard error.
	out, err := output(ctx, c.r, readTimeout, "/bin/sh", "-c", "sysadminctl -screenLock status 2>&1")
	var lock Result
	switch {
	case err != nil:
		lock = unknown(name, err)
	case strings.Contains(out, "screenLock is off"):
		lock = result(name, false, advice)
	case strings.Contains(out, "immediate"):
		lock = result(name, true, advice)
	case lockDelay.MatchString(out):
		seconds, _ := strconv.Atoi(lockDelay.FindStringSubmatch(out)[1])
		lock = result(name, seconds <= 5, advice)
	default:
		lock = unknown(name, fmt.Errorf("unexpected answer %q", strings.TrimSpace(out)))
	}
	return []Result{lock, c.screenSaver(ctx)}
}

// screenSaver reads the idle seconds before the screen saver starts; the key
// is absent until someone sets it, and 0 means never.
func (c Checker) screenSaver(ctx context.Context) Result {
	const name = "screen saver starts within 10 minutes"
	out, err := output(ctx, c.r, readTimeout, "/bin/sh", "-c",
		"defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null; true")
	if err != nil {
		return unknown(name, err)
	}
	idle, err := strconv.Atoi(strings.TrimSpace(out))
	if err != nil || (idle > 0 && idle <= 600) {
		return Result{Name: name, OK: true}
	}
	return Result{Name: name, Warn: true, Detail: "System Settings, Lock Screen: start the screen saver after 10 minutes or less"}
}

// updateKeys are the automatic update settings. Apple turns each on until
// someone turns it off, so an absent key counts as on.
var updateKeys = []string{"CriticalUpdateInstall", "ConfigDataInstall", "AutomaticDownload", "AutomaticallyInstallMacOSUpdates"}

func (c Checker) securityUpdates(ctx context.Context) Result {
	const name = "security updates install on their own"
	var script strings.Builder
	for _, k := range updateKeys {
		fmt.Fprintf(&script, "echo %s=$(defaults read %s %s 2>/dev/null); ", k, softwareUpdate, k)
	}
	out, err := output(ctx, c.r, readTimeout, "/bin/sh", "-c", script.String())
	if err != nil {
		return unknown(name, err)
	}
	var off, absent []string
	for _, line := range strings.Split(out, "\n") {
		key, value, _ := strings.Cut(strings.TrimSpace(line), "=")
		switch {
		case key == "":
		case value == "0":
			off = append(off, key)
		case value == "":
			absent = append(absent, key)
		}
	}
	if len(off) > 0 {
		r := result(name, false, "System Settings, General, Software Update, Automatic updates: turn on downloads, security responses and macOS installs; macOS then installs updates and restarts on its own")
		r.Detail += " (off: " + strings.Join(off, ", ") + ")"
		return r
	}
	r := Result{Name: name, OK: true}
	if len(absent) > 0 {
		r.Detail = "not set, so on by default: " + strings.Join(absent, ", ")
	}
	return r
}

// lastColon splits a listening address at the port. An address with an arrow
// is a connection, not a listener.
func lastColon(addr string) (host, port string, ok bool) {
	i := strings.LastIndex(addr, ":")
	if i < 0 || strings.Contains(addr, "->") {
		return "", "", false
	}
	return addr[:i], addr[i+1:], true
}

// exposed lists servers listening on a wildcard or LAN address, which any
// network you join can reach; a dev server is safer on 127.0.0.1. rapportd is
// macOS's own Continuity service.
func (c Checker) exposed(ctx context.Context) Result {
	const name = "servers on every network interface"
	// lsof exits 1 when nothing listens, so exit 1 is an answer; any other
	// failure is not. Field output, one field a line, keeps whole names with
	// spaces; +c 0 stops it cutting them at 9.
	out, err := output(ctx, c.r, readTimeout, "lsof", "-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-Fcn")
	if err != nil && exitCode(err) != 1 {
		return unknown(name, err)
	}
	var commands []string
	ports := map[string][]string{}
	var command string
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(line, "c"):
			command = line[1:]
		case strings.HasPrefix(line, "n") && command != "rapportd":
			host, port, ok := lastColon(line[1:])
			if !ok || loopback(strings.Trim(host, "[]")) {
				continue
			}
			if !slices.Contains(commands, command) {
				commands = append(commands, command)
			}
			if !slices.Contains(ports[command], port) {
				ports[command] = append(ports[command], port)
			}
		}
	}
	if len(commands) == 0 {
		return Result{Name: name, OK: true}
	}
	// A VM forwarding a hundred ports reads as one entry, not a hundred.
	// ControlCenter listens for AirPlay Receiver, a setting, not a server.
	found := make([]string, len(commands))
	fix := "bind dev servers to 127.0.0.1"
	for i, cmd := range commands {
		label := cmd
		if cmd == "ControlCenter" {
			label = "AirPlay Receiver"
			fix += ", and turn off AirPlay Receiver in System Settings > General > AirDrop & Handoff"
		}
		if p := ports[cmd]; len(p) > 3 {
			found[i] = fmt.Sprintf("%s on %d ports", label, len(p))
		} else {
			found[i] = label + ":" + strings.Join(p, ",")
		}
	}
	return Result{Name: name, Warn: true, Detail: strings.Join(found, " ") + "; " + fix}
}
