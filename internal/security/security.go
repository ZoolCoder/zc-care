// Package security checks that a lost or unlocked Mac does not expose code,
// keys and sessions: disk encryption, the firewall, the screen lock, system
// protections, updates, and servers reachable from the network. It only
// reads; each failed check says how to fix it.
package security

import (
	"context"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"

	"github.com/zoolcoder/zc-care/internal/sh"
)

// Result is one check: ok, or the fix.
type Result struct {
	Name   string
	OK     bool
	Detail string
	// Warn marks a finding to look at rather than a failure.
	Warn bool
}

const firewall = "/usr/libexec/ApplicationFirewall/socketfilterfw"

type check struct {
	name, fix string
	cmd       []string
	pass      func(out string) bool
}

func contains(s string) func(string) bool {
	return func(out string) bool { return strings.Contains(out, s) }
}

var checks = []check{
	{"FileVault disk encryption", "turn FileVault on in System Settings, Privacy & Security",
		[]string{"fdesetup", "status"}, contains("FileVault is On")},
	{"firewall", "sudo " + firewall + " --setglobalstate on",
		[]string{firewall, "--getglobalstate"}, contains("is enabled")},
	{"firewall stealth mode", "sudo " + firewall + " --setstealthmode on",
		[]string{firewall, "--getstealthmode"}, contains("mode is on")},
	// sysadminctl prints its answer to standard error.
	{"password after sleep or screen saver", "System Settings, Lock Screen: require a password immediately",
		[]string{"/bin/sh", "-c", "sysadminctl -screenLock status 2>&1"},
		func(out string) bool {
			return strings.Contains(out, "screenLock") && !strings.Contains(out, "screenLock is off")
		}},
	{"Gatekeeper", "sudo spctl --global-enable",
		[]string{"spctl", "--status"}, contains("assessments enabled")},
	{"System Integrity Protection", "start up in Recovery and run csrutil enable",
		[]string{"csrutil", "status"}, contains("status: enabled")},
	{"automatic update checks", "sudo softwareupdate --schedule on",
		[]string{"softwareupdate", "--schedule"}, contains("turned on")},
	{"security updates install on their own", "System Settings, General, Software Update, Automatic updates: turn on security responses",
		[]string{"/bin/sh", "-c", "defaults read /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall; defaults read /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall"},
		func(out string) bool {
			return strings.Fields(out) != nil && slices.Equal(strings.Fields(out), []string{"1", "1"})
		}},
	{"File Sharing off", "sudo launchctl disable system/com.apple.smbd",
		[]string{"netstat", "-an", "-p", "tcp"},
		func(out string) bool { return !smb.MatchString(out) }},
	{"Remote Login off", "System Settings, General, Sharing: turn Remote Login off, or limit it to your user",
		[]string{"netstat", "-an", "-p", "tcp"},
		func(out string) bool { return !sshd.MatchString(out) }},
	{"Screen Sharing off", "System Settings, General, Sharing: turn Screen Sharing and Remote Management off",
		[]string{"netstat", "-an", "-p", "tcp"},
		func(out string) bool { return !vnc.MatchString(out) }},
	// Each reads a key that is absent on a safe Mac, so the shell forgives
	// the error and an empty answer passes.
	{"automatic login off", "System Settings, Users & Groups: set Automatically log in as to Off",
		[]string{"/bin/sh", "-c", "defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null; true"},
		func(out string) bool { return strings.TrimSpace(out) == "" }},
	// A Mac without a backup disk says so on standard error.
	{"Time Machine backups", "System Settings, General, Time Machine: add a backup disk",
		[]string{"/bin/sh", "-c", "tmutil destinationinfo 2>&1; true"},
		func(out string) bool { return strings.Contains(out, "Name") }},
	{"AirDrop not open to everyone", "System Settings, General, AirDrop & Handoff: set AirDrop to Contacts Only",
		[]string{"/bin/sh", "-c", "defaults read com.apple.sharingd DiscoverableMode 2>/dev/null; true"},
		func(out string) bool { return !strings.Contains(out, "Everyone") }},
}

var (
	smb  = regexp.MustCompile(`[.:]445 .*LISTEN`)
	sshd = regexp.MustCompile(`[.:]22 .*LISTEN`)
	vnc  = regexp.MustCompile(`[.:]5900 .*LISTEN`)
	// touchID is the line sudo_local.template ships commented out.
	touchID = regexp.MustCompile(`(?m)^auth\s+sufficient\s+pam_tid\.so`)
)

// Checker runs the checks through r; pam is the sudo PAM file that enables
// Touch ID.
type Checker struct {
	r   sh.Runner
	pam string
}

func New(r sh.Runner) Checker { return Checker{r: r, pam: "/etc/pam.d/sudo_local"} }

// Run runs every check, in a fixed order.
func (c Checker) Run(ctx context.Context) []Result {
	var results []Result
	for _, ch := range checks {
		out, err := c.r.Output(ctx, ch.cmd[0], ch.cmd[1:]...)
		results = append(results, result(ch.name, err == nil && ch.pass(string(out)), ch.fix))
	}
	pam, _ := os.ReadFile(c.pam)
	results = append(results, result("Touch ID for sudo", touchID.Match(pam),
		`sed "s/^#auth/auth/" /etc/pam.d/sudo_local.template | sudo tee /etc/pam.d/sudo_local`))
	return append(results, c.exposed(ctx))
}

func result(name string, ok bool, fix string) Result {
	if ok {
		return Result{Name: name, OK: true}
	}
	return Result{Name: name, Detail: fix}
}

// exposed lists servers listening on every network interface, which any
// network you join can reach; a dev server is safer on 127.0.0.1. rapportd is
// macOS's own Continuity service.
func (c Checker) exposed(ctx context.Context) Result {
	const name = "servers on every network interface"
	// lsof exits 1 when nothing listens. Field output, one field a line,
	// keeps whole names with spaces; +c 0 stops it cutting them at 9.
	out, _ := c.r.Output(ctx, "lsof", "-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-Fcn")
	var commands []string
	ports := map[string][]string{}
	var command string
	for _, line := range strings.Split(string(out), "\n") {
		switch {
		case strings.HasPrefix(line, "c"):
			command = line[1:]
		case strings.HasPrefix(line, "n*:") && command != "rapportd":
			if !slices.Contains(commands, command) {
				commands = append(commands, command)
			}
			if port := line[3:]; !slices.Contains(ports[command], port) {
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
