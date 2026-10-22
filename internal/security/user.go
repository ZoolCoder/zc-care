package security

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/zoolcoder/zc-care/internal/sh"
)

// scanTimeout bounds one gitleaks run over a long history.
const scanTimeout = 60 * time.Second

// User checks what lives in the home folder on every system: keys that open
// without a passphrase, unsigned commits, secrets typed into the shell, and
// the configs that hand tools to AI agents. Like Checker, it only reads, and
// it never prints a secret, only where one is.
type User struct {
	r    sh.Runner
	home string
	// fileExists stands in for os.Stat, so tests do not look outside their
	// own folder.
	fileExists func(string) bool
}

func NewUser(r sh.Runner) User {
	home, _ := os.UserHomeDir()
	return User{r: r, home: home}
}

// Account runs the checks on keys, commits and shell history.
func (u User) Account(ctx context.Context) []Result {
	return []Result{u.sshKeys(), u.commitSigning(ctx), u.historySecrets(ctx)}
}

// sshKeys names the private keys in ~/.ssh that open without a passphrase:
// anyone who copies the file can use them.
func (u User) sshKeys() Result {
	const name = "SSH keys have a passphrase"
	entries, _ := os.ReadDir(filepath.Join(u.home, ".ssh"))
	var open, unreadable []string
	for _, e := range entries {
		if e.IsDir() || strings.HasSuffix(e.Name(), ".pub") || notAKey(e.Name()) {
			continue
		}
		b, err := os.ReadFile(filepath.Join(u.home, ".ssh", e.Name()))
		if err != nil {
			continue
		}
		unprotected, err := unprotectedKey(b)
		switch {
		case err != nil:
			unreadable = append(unreadable, e.Name())
		case unprotected:
			open = append(open, e.Name())
		}
	}
	var detail []string
	if len(open) > 0 {
		detail = append(detail, strings.Join(open, " ")+
			" open without a passphrase; add one with ssh-keygen -p -f ~/.ssh/<key>, or keep the key in a hardware or password-manager agent")
	}
	if len(unreadable) > 0 {
		detail = append(detail, "could not parse "+strings.Join(unreadable, " "))
	}
	switch {
	case len(open) > 0:
		return Result{Name: name, Warn: true, Detail: strings.Join(detail, "; ")}
	case len(unreadable) > 0:
		return Result{Name: name, Unknown: true, Detail: strings.Join(detail, "; ")}
	}
	return Result{Name: name, OK: true}
}

// notAKey is a file ssh keeps beside the keys, which holds none.
func notAKey(name string) bool {
	return slices.Contains([]string{"config", "environment", "rc", "allowed_signers", ".DS_Store"}, name) ||
		strings.HasPrefix(name, "known_hosts") || strings.HasPrefix(name, "authorized_keys")
}

var errUnparsedKey = errors.New("could not parse the key")

// unprotectedKey reads a private key's header: an OpenSSH key names its
// cipher, a PEM key says ENCRYPTED when it has a passphrase. A FIDO key
// (sk-...) is only a handle to the hardware token, so it holds no secret. A
// key whose header does not parse is an error, not a pass.
func unprotectedKey(b []byte) (bool, error) {
	const openssh = "-----BEGIN OPENSSH PRIVATE KEY-----"
	switch {
	case bytes.Contains(b, []byte(openssh)):
		body := string(b[bytes.Index(b, []byte(openssh))+len(openssh):])
		body, _, _ = strings.Cut(body, "-----END")
		raw, err := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(body), ""))
		magic := "openssh-key-v1\x00"
		if err != nil || !strings.HasPrefix(string(raw), magic) {
			return false, errUnparsedKey
		}
		// cipher, kdf, kdf options, key count, then the public key blob.
		raw = raw[len(magic):]
		cipher, raw, ok := sshString(raw)
		for i := 0; i < 2 && ok; i++ {
			_, raw, ok = sshString(raw)
		}
		if !ok || len(raw) < 4 {
			return false, errUnparsedKey
		}
		blob, _, ok := sshString(raw[4:])
		keyType, _, _ := sshString(blob)
		if !ok {
			return false, errUnparsedKey
		}
		return string(cipher) == "none" && !strings.HasPrefix(string(keyType), "sk-"), nil
	case bytes.Contains(b, []byte("PRIVATE KEY-----")):
		return !bytes.Contains(b, []byte("ENCRYPTED")), nil
	}
	return false, errUnparsedKey
}

// sshString reads one length-prefixed field of the OpenSSH key format.
func sshString(b []byte) (field, rest []byte, ok bool) {
	if len(b) < 4 {
		return nil, nil, false
	}
	n := binary.BigEndian.Uint32(b)
	if uint64(n) > uint64(len(b)-4) {
		return nil, nil, false
	}
	return b[4 : 4+n], b[4+n:], true
}

// signingSettings are the git settings that make commits carry an SSH signature.
const signingSettings = `^(commit\.gpgsign|gpg\.format|user\.signingkey)$`

// commitSigning checks that git signs commits with an SSH key that exists,
// so a pushed commit provably came from this machine's key.
func (u User) commitSigning(ctx context.Context) Result {
	const name = "git signs commits"
	// --global alone skips [include]d files, where dotfiles often keep it.
	out, err := output(ctx, u.r, readTimeout, "git", "config", "--global", "--includes", "--get-regexp", signingSettings)
	if err != nil && exitCode(err) != 1 {
		return unknown(name, err)
	}
	set := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		key, value, _ := strings.Cut(strings.TrimSpace(line), " ")
		set[key] = strings.TrimSpace(value)
	}
	var steps []string
	if set["gpg.format"] != "ssh" {
		steps = append(steps, "git config --global gpg.format ssh")
	}
	switch key := set["user.signingkey"]; {
	case key == "":
		steps = append(steps, "git config --global user.signingkey <path to your .pub key>")
	case !u.keyExists(key):
		steps = append(steps, "user.signingkey names "+key+", which does not exist; point it at your .pub key")
	}
	if set["commit.gpgsign"] != "true" {
		steps = append(steps, "git config --global commit.gpgsign true")
	}
	if len(steps) == 0 {
		return Result{Name: name, OK: true}
	}
	return Result{Name: name, Warn: true, Detail: strings.Join(steps, "; ")}
}

// keyExists reports whether the signing key is there. A key written out in
// the setting (key:: or ssh-...) is not a file, so it counts.
func (u User) keyExists(key string) bool {
	if strings.HasPrefix(key, "key::") || strings.HasPrefix(key, "ssh-") || strings.HasPrefix(key, "ecdsa-") || strings.HasPrefix(key, "sk-") {
		return true
	}
	if rest, ok := strings.CutPrefix(key, "~/"); ok {
		key = filepath.Join(u.home, rest)
	}
	if u.fileExists != nil {
		return u.fileExists(key)
	}
	_, err := os.Stat(key)
	return err == nil
}

// historySecrets runs gitleaks over the shell histories and atuin's, and
// reports which rules matched where. --redact keeps the secret itself out of
// what gitleaks returns. A scan that failed says so: it is not a clean one.
func (u User) historySecrets(ctx context.Context) Result {
	const name = "no secrets in shell history"
	if !u.r.Has("gitleaks") {
		return Result{Name: name, Warn: true, Detail: "install gitleaks to check: brew install gitleaks"}
	}
	scan := []string{"--no-banner", "--redact", "--report-format", "json", "--report-path", "-", "--exit-code", "0"}
	var found, failed []string
	record := func(where, report string, err error) {
		if err == nil {
			var hits []string
			if hits, err = leaks(where, []byte(report)); err == nil {
				found = append(found, hits...)
				return
			}
		}
		failed = append(failed, where+": "+err.Error())
	}
	for _, f := range []string{".zsh_history", ".bash_history", ".local/share/fish/fish_history"} {
		path := filepath.Join(u.home, f)
		if _, err := os.Stat(path); err != nil {
			continue
		}
		out, err := output(ctx, u.r, scanTimeout, append([]string{"gitleaks", "dir", path}, scan...)...)
		record("~/"+f, out, err)
	}
	if u.r.Has("atuin") {
		// pipefail makes a failing atuin fail the scan, not pass it as empty.
		out, err := output(ctx, u.r, scanTimeout, "/bin/sh", "-c",
			"set -o pipefail; atuin history list --cmd-only | gitleaks stdin "+strings.Join(scan, " "))
		record("atuin", out, err)
	}
	var detail []string
	if len(failed) > 0 {
		detail = append(detail, "gitleaks failed: "+strings.Join(failed, ", "))
	}
	if len(found) > 0 {
		detail = append(detail, strings.Join(found, ", ")+"; rotate those secrets, then delete the lines from the history")
	}
	if len(detail) == 0 {
		return Result{Name: name, OK: true}
	}
	return Result{Name: name, Warn: true, Detail: strings.Join(detail, "; ")}
}

// leaks summarises a gitleaks JSON report as "where: rule xN". gitleaks
// prints [] when it finds nothing, so anything but a JSON array is an error.
func leaks(where string, report []byte) ([]string, error) {
	if !bytes.HasPrefix(bytes.TrimSpace(report), []byte("[")) {
		return nil, errors.New("no JSON report")
	}
	var findings []struct{ RuleID string }
	if err := json.Unmarshal(report, &findings); err != nil {
		return nil, fmt.Errorf("unreadable report: %w", err)
	}
	count := map[string]int{}
	var rules []string
	for _, f := range findings {
		if count[f.RuleID] == 0 {
			rules = append(rules, f.RuleID)
		}
		count[f.RuleID]++
	}
	slices.Sort(rules)
	var out []string
	for _, r := range rules {
		out = append(out, fmt.Sprintf("%s: %s x%d", where, r, count[r]))
	}
	return out, nil
}
