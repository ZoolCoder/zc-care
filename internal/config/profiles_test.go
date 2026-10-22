package config

import "testing"

func TestTargetFor(t *testing.T) {
	tests := []struct {
		name            string
		target, machine []string
		want            bool
	}{
		{"no restriction", nil, []string{"work"}, true},
		{"machine without profiles", []string{"work"}, nil, true},
		{"match", []string{"work", "dev"}, []string{"dev"}, true},
		{"no match", []string{"work"}, []string{"home"}, false},
	}
	for _, tt := range tests {
		if got := (Target{Profiles: tt.target}).For(tt.machine); got != tt.want {
			t.Errorf("%s: got %v", tt.name, got)
		}
	}
}
