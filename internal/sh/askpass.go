package sh

import (
	"os"
	"path/filepath"
)

// askpassScript asks for the password in a macOS dialog. sudo runs it in
// place of its terminal prompt; Touch ID still comes first when it is set up.
const askpassScript = `#!/bin/sh
exec /usr/bin/osascript \
  -e 'display dialog "zc-care needs your password to install or remove software." default answer "" with hidden answer with title "zc-care" with icon caution' \
  -e 'text returned of result'
`

// askpassEnv is the environment for a program that may run sudo. With no
// terminal to prompt on, as under an AI agent or launchd, it points
// SUDO_ASKPASS at the dialog; Homebrew then passes -A, and sudo uses the
// dialog on its own once DISPLAY is set. Otherwise it is nil: inherit as is.
func askpassEnv() []string {
	if os.Getenv("SUDO_ASKPASS") != "" || hasTerminal() {
		return nil
	}
	path, err := writeAskpass()
	if err != nil {
		return nil
	}
	env := append(os.Environ(), "SUDO_ASKPASS="+path)
	if os.Getenv("DISPLAY") == "" {
		env = append(env, "DISPLAY=:0")
	}
	return env
}

// hasTerminal reports whether this process has a controlling terminal, the
// same test sudo makes before it prompts.
func hasTerminal() bool {
	tty, err := os.Open("/dev/tty")
	if err != nil {
		return false
	}
	return tty.Close() == nil
}

func writeAskpass() (string, error) {
	dir, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, "zc-care", "askpass")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	return path, os.WriteFile(path, []byte(askpassScript), 0o700)
}
