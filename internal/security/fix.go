package security

import "strings"

// touchIDScript turns Touch ID on in the sudo PAM file at path, keeping
// every other line: it uncomments the pam_tid line, or appends it when the
// file lacks one or does not exist. Only an auth sufficient line counts as
// the pam_tid line, which is what the check needs: another form, such as
// auth optional, or a comment that mentions the module, gets the line
// appended. An append first ends a last line that has no newline. The body
// holds no single quote, so Line renders it as one single-quoted argument.
func touchIDScript(path string) string {
	return `f=` + path + `; if grep -Eq "^#*[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so" $f 2>/dev/null; then ` +
		`sed -i "" "s/^#[[:space:]]*\(auth[[:space:]][[:space:]]*sufficient[[:space:]][[:space:]]*pam_tid\.so\)/\1/" $f; ` +
		`else [ -s $f ] && [ -n "$(tail -c1 $f)" ] && echo >> $f; ` +
		`printf "auth       sufficient     pam_tid.so\n" >> $f; fi`
}

// fixes are the commands that repair a failed check, by check name. A check
// missing here has no command that is safe to run unasked: it needs a
// choice, a password, Recovery, or a visit to System Settings, and stays
// advice: AirDrop, whose setting is a System Settings choice, and security
// updates, where macOS then installs and restarts unasked. The command is
// what Result.Detail shows, as argv; a leading sudo is the only privilege
// escalation, and doctor -fix lists each one.
var fixes = map[string][][]string{
	"firewall":                {{"sudo", firewall, "--setglobalstate", "on"}},
	"firewall stealth mode":   {{"sudo", firewall, "--setstealthmode", "on"}},
	"Gatekeeper":              {{"sudo", "spctl", "--global-enable"}},
	"automatic update checks": {{"sudo", "softwareupdate", "--schedule", "on"}},
	// disable stops smbd at the next boot; bootout stops the running one,
	// and fails when none runs.
	"File Sharing off": {{"sudo", "/bin/sh", "-c", "launchctl disable system/com.apple.smbd; launchctl bootout system/com.apple.smbd 2>/dev/null; true"}},
	// kcpassword holds the login password that automatic login uses.
	"automatic login off": {{"sudo", "/bin/sh", "-c", "rm -f /etc/kcpassword; defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser"}},
	"Guest account off":   {{"sudo", "sysadminctl", "-guestAccount", "off"}},
	"Touch ID for sudo":   {{"sudo", "/bin/sh", "-c", touchIDScript("/etc/pam.d/sudo_local")}},
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
