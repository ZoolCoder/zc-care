package main

import (
	"bytes"
	"testing"

	"github.com/zoolcoder/toolshell/doctor"
	"github.com/zoolcoder/zc-care/internal/security"
)

func TestSecurityStatuses(t *testing.T) {
	r := doctor.New("test")
	addSecurity(r, "security ", security.Result{Name: "a", OK: true})
	addSecurity(r, "security ", security.Result{Name: "b", Detail: "fix it"})
	addSecurity(r, "ai ", security.Result{Name: "c", Warn: true, Detail: "look"})
	addSecurity(r, "security ", security.Result{Name: "d", Unknown: true, Detail: "could not read: boom"})
	want := []doctor.Check{
		{Name: "security a", Status: doctor.OK},
		{Name: "security b", Status: doctor.Warn, Detail: "fix it"},
		{Name: "ai c", Status: doctor.Warn, Detail: "look"},
		{Name: "security d", Status: "unknown", Detail: "could not read: boom"},
	}
	for i, c := range want {
		if r.Checks[i] != c {
			t.Errorf("check %d = %+v, want %+v", i, r.Checks[i], c)
		}
	}
	if err := r.Write(&bytes.Buffer{}, true); err != nil {
		t.Errorf("unknown must not fail doctor: %v", err)
	}
}
