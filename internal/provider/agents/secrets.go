package agents

import (
	"context"
	"fmt"
	"maps"
	"regexp"
	"strings"

	"github.com/zoolcoder/zc-care/internal/sh"
)

// A server value may hold ${keychain:service} or ${keychain:service/account}.
// The secret is read from the login keychain when the server is compared or
// written. Plans, history and errors name the reference, never the secret.
var (
	// anyRef finds every attempt at a reference, even a malformed one.
	anyRef = regexp.MustCompile(`\$\{keychain:[^}]*\}?`)
	// goodRef is one well-formed reference: a service, then optionally an
	// account after the first slash.
	goodRef = regexp.MustCompile(`^\$\{keychain:([^/}\s]+)(?:/([^}\s]+))?\}$`)
)

// wellFormed reports whether every reference in v is well formed.
func wellFormed(v string) bool {
	for _, ref := range anyRef.FindAllString(v, -1) {
		if !goodRef.MatchString(ref) {
			return false
		}
	}
	return true
}

// eachValue replaces every string of s that may hold a reference with
// f's result, stopping at the first error.
func eachValue(s *Server, f func(string) (string, error)) error {
	var err error
	set := func(v *string) {
		if err == nil {
			*v, err = f(*v)
		}
	}
	set(&s.Command)
	set(&s.URL)
	for i := range s.Args {
		set(&s.Args[i])
	}
	for _, m := range []map[string]string{s.Env, s.Headers} {
		for k, v := range m {
			set(&v)
			m[k] = v
		}
	}
	return err
}

// keychain reads secrets through security, once per reference.
type keychain struct {
	r    sh.Runner
	seen map[string]string
}

func newKeychain(r sh.Runner) *keychain { return &keychain{r: r, seen: map[string]string{}} }

// server is s with every reference replaced by its secret; s is unchanged.
func (k *keychain) server(ctx context.Context, s Server) (Server, error) {
	s.Args = append([]string(nil), s.Args...)
	s.Env, s.Headers = maps.Clone(s.Env), maps.Clone(s.Headers)
	err := eachValue(&s, func(v string) (string, error) { return k.expand(ctx, v) })
	return s, err
}

func (k *keychain) expand(ctx context.Context, v string) (string, error) {
	var err error
	out := anyRef.ReplaceAllStringFunc(v, func(ref string) string {
		if err != nil {
			return ref
		}
		var secret string
		secret, err = k.lookup(ctx, ref)
		return secret
	})
	return out, err
}

func (k *keychain) lookup(ctx context.Context, ref string) (string, error) {
	if secret, ok := k.seen[ref]; ok {
		return secret, nil
	}
	m := goodRef.FindStringSubmatch(ref)
	if m == nil {
		return "", fmt.Errorf("malformed secret reference %s", ref)
	}
	service, account := m[1], m[2]
	args := []string{"find-generic-password", "-s", service}
	add := "security add-generic-password -s " + service + " -a $USER -w"
	if account != "" {
		args = append(args, "-a", account)
		add = "security add-generic-password -s " + service + " -a " + account + " -w"
	}
	out, err := k.r.Output(ctx, "security", append(args, "-w")...)
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	if err != nil {
		return "", fmt.Errorf("secret %s is not in the keychain; add it with: %s", ref, add)
	}
	k.seen[ref] = strings.TrimSuffix(string(out), "\n")
	return k.seen[ref], nil
}
