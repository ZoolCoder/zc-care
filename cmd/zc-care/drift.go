package main

import (
	"bytes"
	"encoding/json"
	"encoding/xml"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/zoolcoder/toolshell/activity"
	"github.com/zoolcoder/toolshell/mcp"
	"github.com/zoolcoder/zc-care/internal/plan"
)

// driftLabel names the launchd agent that runs drift every morning.
const driftLabel = "dev.zoolcoder.zc-care.drift"

// Drift is how far the machine has moved from the config, as the last drift
// run saw it. ZC Care and SketchyBar read it from drift.json.
type Drift struct {
	At      time.Time      `json:"at"`
	Changes int            `json:"changes"`
	Manual  int            `json:"manual"`
	Targets map[string]int `json:"targets"`
	Error   string         `json:"error,omitempty"`
}

func driftFile() string { return filepath.Join(mcp.StateDir(name), "drift.json") }

// runDrift plans, saves the count of outstanding changes, and logs a change
// in that count to history. It applies nothing.
func runDrift(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("drift", flag.ContinueOnError)
	flags.SetOutput(stderr)
	path := flags.String("config", "", "config file")
	last := flags.Bool("last", false, "print the last saved drift, without planning")
	asJSON := flags.Bool("json", false, "machine-readable output")
	plist := flags.Bool("plist", false, "print a launchd agent that runs drift every morning")
	at := flags.Int("hour", 9, "plist: the hour to run at")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *plist {
		return writePlist(stdout, findConfig(*path), *at)
	}

	var d Drift
	if *last {
		b, err := os.ReadFile(driftFile())
		if errors.Is(err, os.ErrNotExist) {
			return errors.New("no drift saved yet: run " + name + " drift")
		}
		if err != nil {
			return err
		}
		if err := json.Unmarshal(b, &d); err != nil {
			return fmt.Errorf("%s: %w", driftFile(), err)
		}
	} else {
		d = measureDrift(*path, stdin, stderr)
		if err := saveDrift(d); err != nil {
			return err
		}
	}
	if *asJSON {
		return writeJSON(stdout, d)
	}
	_, err := fmt.Fprintln(stdout, d.summary())
	return err
}

func measureDrift(path string, stdin io.Reader, stderr io.Writer) Drift {
	d := Drift{At: time.Now().UTC(), Targets: map[string]int{}}
	args := []string{"plan", "-json"}
	if path != "" {
		args = append(args, "-config", path)
	}
	var out bytes.Buffer
	if err := runCLI(args, stdin, &out, stderr); err != nil {
		d.Error = err.Error()
		return d
	}
	var p struct {
		Changes int               `json:"changes"`
		Manual  int               `json:"manual"`
		Actions []plan.JSONAction `json:"actions"`
	}
	if err := json.Unmarshal(out.Bytes(), &p); err != nil {
		d.Error = "read plan: " + err.Error()
		return d
	}
	d.Changes, d.Manual = p.Changes, p.Manual
	for _, a := range p.Actions {
		if !a.Manual {
			d.Targets[a.Target]++
		}
	}
	return d
}

// saveDrift writes drift.json, records a change since the last run in
// history, and tells SketchyBar to redraw.
func saveDrift(d Drift) error {
	var before Drift
	if b, err := os.ReadFile(driftFile()); err == nil {
		_ = json.Unmarshal(b, &before)
	}
	b, err := json.MarshalIndent(d, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(driftFile()), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(driftFile(), append(b, '\n'), 0o600); err != nil {
		return err
	}
	if before.At.IsZero() || before.Changes != d.Changes || before.Error != d.Error {
		_ = activityLog("").Append(activity.Entry{At: d.At, Kind: "drift", Detail: d.summary(), OK: d.Error == ""})
	}
	return nil
}

func (d Drift) summary() string {
	switch {
	case d.Error != "":
		return "drift unknown: " + d.Error
	case d.Changes == 0:
		return "no drift: everything matches the config"
	}
	targets := make([]string, 0, len(d.Targets))
	for t, n := range d.Targets {
		targets = append(targets, fmt.Sprintf("%s %d", t, n))
	}
	slices.Sort(targets)
	return fmt.Sprintf("%d change(s) outstanding: %s; run %s plan", d.Changes, strings.Join(targets, ", "), name)
}

// writePlist prints a launchd agent for the services provider to keep
// loaded. It names the binary on PATH, which survives a Homebrew upgrade, and
// carries today's PATH, since launchd starts agents with almost none and plan
// needs brew, mise and chezmoi.
func writePlist(w io.Writer, config string, hour int) error {
	bin, err := exec.LookPath(name)
	if err != nil {
		if bin, err = os.Executable(); err != nil {
			return err
		}
	}
	if config != "" {
		if config, err = filepath.Abs(config); err != nil {
			return err
		}
	}
	log := filepath.Join(mcp.StateDir(name), "drift.log")
	_, err = fmt.Fprintf(w, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>drift</string>
    <string>-config</string>
    <string>%s</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>%s</string></dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>%d</integer><key>Minute</key><integer>0</integer></dict>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
`, driftLabel, xmlText(bin), xmlText(config), xmlText(os.Getenv("PATH")), hour, xmlText(log), xmlText(log))
	return err
}

func xmlText(s string) string {
	var b strings.Builder
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}
