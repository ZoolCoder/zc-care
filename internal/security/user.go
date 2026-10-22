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
	var open []string
	for _, e := range entries {
		if e.IsDir() || strings.HasSuffix(e.Name(), ".pub") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(u.home, ".ssh", e.Name()))
		if err == nil && unprotectedKey(b) {
			open = append(open, e.Name())
		}
	}
	if len(open) == 0 {
		return Result{Name: name, OK: true}
	}
	return Result{Name: name, Warn: true, Detail: strings.Join(open, " ") +
		" open without a passphrase; add one with ssh-keygen -p -f ~/.ssh/<key>, or keep the key in a hardware or password-manager agent"}
}

// unprotectedKey reads a private key's header: an OpenSSH key names its
// cipher, a PEM key says ENCRYPTED when it has a passphrase. A FIDO key
// (sk-...) is only a handle to the hardware token, so it holds no secret.
func unprotectedKey(b []byte) bool {
	const openssh = "-----BEGIN OPENSSH PRIVATE KEY-----"
	switch {
	case bytes.Contains(b, []byte(openssh)):
		body := string(b[bytes.Index(b, []byte(openssh))+len(openssh):])
		body, _, _ = strings.Cut(body, "-----END")
		raw, err := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(body), ""))
		magic := "openssh-key-v1\x00"
		if err != nil || !strings.HasPrefix(string(raw), magic) {
			return false
		}
		// cipher, kdf, kdf options, key count, then the public key blob.
		raw = raw[len(magic):]
		cipher, raw, ok := sshString(raw)
		for i := 0; i < 2 && ok; i++ {
			_, raw, ok = sshString(raw)
		}
		if !ok || len(raw) < 4 {
			return false
		}
		blob, _, ok := sshString(raw[4:])
		keyType, _, _ := sshString(blob)
		if !ok {
			return false
		}
		return string(cipher) == "none" && !strings.HasPrefix(string(keyType), "sk-")
	case bytes.Contains(b, []byte("PRIVATE KEY-----")):
		return !bytes.Contains(b, []byte("ENCRYPTED"))
	}
	return false
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

// commitSigning checks that git signs commits, so a pushed commit provably
// came from this machine's key.
func (u User) commitSigning(ctx context.Context) Result {
	const name = "git signs commits"
	// --global alone skips [include]d files, where dotfiles often keep it.
	out, _ := u.r.Output(ctx, "git", "config", "--global", "--includes", "--get", "commit.gpgsign")
	if strings.TrimSpace(string(out)) == "true" {
		return Result{Name: name, OK: true}
	}
	return Result{Name: name, Warn: true, Detail: "git config --global gpg.format ssh; " +
		"git config --global user.signingkey ~/.ssh/id_ed25519.pub; git config --global commit.gpgsign true"}
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
