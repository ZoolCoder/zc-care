// Package sh runs the package managers and tools the providers drive.
// Providers take a Runner, so tests swap in Fake and never touch the machine.
package sh

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"slices"
	"strings"
)

// Runner starts programs.
type Runner interface {
	// Output runs a program and returns its standard output. A non-zero exit
	// is an error that carries the program's standard error.
	Output(ctx context.Context, name string, args ...string) ([]byte, error)
	// Run runs a program attached to the terminal, for installs that may
	// prompt (sudo, a license, a password manager). Without a terminal, sudo
	// asks in a dialog instead.
	Run(ctx context.Context, name string, args ...string) error
	// Has reports whether a program is on PATH.
	Has(name string) bool
}

// Exec is the Runner for the real machine.
type Exec struct {
	Stdin          io.Reader
	Stdout, Stderr io.Writer
}

// System runs programs attached to this process's terminal.
func System() Exec { return Exec{Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr} }

func (Exec) Output(ctx context.Context, name string, args ...string) ([]byte, error) {
	var stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return out, fmt.Errorf("%s: %w: %s", Line(name, args...), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

func (e Exec) Run(ctx context.Context, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = e.Stdin, e.Stdout, e.Stderr
	cmd.Env = askpassEnv()
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s: %w", Line(name, args...), err)
	}
	return nil
}

func (Exec) Has(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

// Line is a command as a person would type it, for messages and fakes.
func Line(name string, args ...string) string {
	return strings.TrimSpace(name + " " + strings.Join(args, " "))
}

// Fake answers commands from a table keyed by Line, and records what Run was
// asked to do.
type Fake struct {
	// Out maps a command line to its standard output.
	Out map[string]string
	// Err maps a command line to the error it fails with.
	Err map[string]error
	// Programs are the names Has finds.
	Programs []string
	// Ran is every command Run was given, in order.
	Ran []string
	// OnRun, when set, sees each Run, so a test can make an install take
	// effect in Out.
	OnRun func(line string)
}

func (f *Fake) Output(_ context.Context, name string, args ...string) ([]byte, error) {
	line := Line(name, args...)
	if err, ok := f.Err[line]; ok {
		return nil, err
	}
	out, ok := f.Out[line]
	if !ok {
		return nil, fmt.Errorf("fake: no answer for %q", line)
	}
	return []byte(out), nil
}

func (f *Fake) Run(_ context.Context, name string, args ...string) error {
	line := Line(name, args...)
	f.Ran = append(f.Ran, line)
	if err, ok := f.Err[line]; ok {
		return err
	}
	if f.OnRun != nil {
		f.OnRun(line)
	}
	return nil
}

func (f *Fake) Has(name string) bool { return slices.Contains(f.Programs, name) }
