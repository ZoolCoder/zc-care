package security

import "strings"

// touchIDScript turns Touch ID on in the sudo PAM file at path, keeping
// every other line: it uncomments the pam_tid line, or appends it when the
// file lacks one or does not exist.
func touchIDScript(path string) string {
	return `f=` + path + `; if grep -q pam_tid.so $f 2>/dev/null; then ` +
		`sed -i "" "s/^#[[:space:]]*\(auth[[:space:]].*pam_tid\.so\)/\1/" $f; ` +
		`else printf "auth       sufficient     pam_tid.so\n" >> $f; fi`
}

// fixes are the commands that repair a failed check, by check name. A check
// missing here has no command that is safe to run unasked: it needs a
// choice, a password, Recovery, or a visit to System Settings, and stays
// advice. The commands are what Result.Detail shows, as argv; a leading
// sudo is the only privilege escalation, and doctor -fix lists each one.
var fixes = map[string][][]string{
	"firewall":                {{"sudo", firewall, "--setglobalstate", "on"}},
	"firewall stealth mode":   {{"sudo", firewall, "--setstealthmode", "on"}},
	"Gatekeeper":              {{"sudo", "spctl", "--global-enable"}},
	"automatic update checks": {{"sudo", "softwareupdate", "--schedule", "on"}},
	// disable stops smbd at the next boot; bootout stops the running one,
	// and fails when none runs.
	"File Sharing off": {{"sudo", "/bin/sh", "-c", "launchctl disable system/com.apple.smbd; launchctl bootout system/com.apple.smbd 2>/dev/null; true"}},
	// kcpassword holds the login password that automatic login uses.
	"automatic login off":          {{"sudo", "/bin/sh", "-c", "rm -f /etc/kcpassword; defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser"}},
	"Guest account off":            {{"sudo", "sysadminctl", "-guestAccount", "off"}},
	"AirDrop not open to everyone": {{"defaults", "write", "com.apple.sharingd", "DiscoverableMode", "-string", "Contacts Only"}},
	"security updates install on their own": {
		{"sudo", "defaults", "write", softwareUpdate, "CriticalUpdateInstall", "-bool", "true"},
		{"sudo", "defaults", "write", softwareUpdate, "ConfigDataInstall", "-bool", "true"},
		{"sudo", "defaults", "write", softwareUpdate, "AutomaticDownload", "-bool", "true"},
		{"sudo", "defaults", "write", softwareUpdate, "AutomaticallyInstallMacOSUpdates", "-bool", "true"},
	},
	"Touch ID for sudo": {{"sudo", "/bin/sh", "-c", touchIDScript("/etc/pam.d/sudo_local")}},
}

// fixLine is the first fix command of a check as a person would type it.
func fixLine(name string) string { return Line(fixes[name][0]) }

// Root reports whether running the command needs administrator rights.
func Root(argv []string) bool { return len(argv) > 0 && argv[0] == "sudo" }

// Line is a command as a person would type it, quoting an argument that has
// a space or a shell character, so what a plan lists is what runs.
func Line(argv []string) string {
	parts := make([]string, len(argv))
	for i, a := range argv {
		parts[i] = a
		if a == "" || strings.ContainsAny(a, " \t\"'$`\\;&|<>*?#~") {
			parts[i] = "'" + strings.ReplaceAll(a, "'", `'\''`) + "'"
		}
	}
	return strings.Join(parts, " ")
}
