package security

import "strings"

// fixes are the commands that repair a failed check, by check name. A check
// missing here has no command that is safe to run unasked: it needs a
// choice, a password, Recovery, or a visit to System Settings, and stays
// advice. The commands are what Result.Detail shows, as argv; a leading
// sudo is the only privilege escalation, and doctor -fix lists each one.
var fixes = map[string][][]string{
	"firewall":                     {{"sudo", firewall, "--setglobalstate", "on"}},
	"firewall stealth mode":        {{"sudo", firewall, "--setstealthmode", "on"}},
	"Gatekeeper":                   {{"sudo", "spctl", "--global-enable"}},
	"automatic update checks":      {{"sudo", "softwareupdate", "--schedule", "on"}},
	"File Sharing off":             {{"sudo", "launchctl", "disable", "system/com.apple.smbd"}},
	"automatic login off":          {{"sudo", "defaults", "delete", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"}},
	"AirDrop not open to everyone": {{"defaults", "write", "com.apple.sharingd", "DiscoverableMode", "-string", "Contacts Only"}},
	"security updates install on their own": {
		{"sudo", "defaults", "write", "/Library/Preferences/com.apple.SoftwareUpdate", "CriticalUpdateInstall", "-bool", "true"},
		{"sudo", "defaults", "write", "/Library/Preferences/com.apple.SoftwareUpdate", "ConfigDataInstall", "-bool", "true"},
	},
	"Touch ID for sudo": {{"sudo", "/bin/sh", "-c", `sed "s/^#auth/auth/" /etc/pam.d/sudo_local.template > /etc/pam.d/sudo_local`}},
}

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
