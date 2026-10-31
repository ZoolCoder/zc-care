package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/provider/packages"
	"github.com/zoolcoder/zc-care/internal/starter"
)

func init() {
	optional["init"] = runInit
	optional["profile"] = runProfile
	optionalUsage = append(optionalUsage,
		"  "+name+" init     -profile p[,p] [-role r] [-from-mac] [-dir d] [-force] [-json]\n"+
			"                                write a starter config for this Mac; -list shows the profiles\n",
		"  "+name+" profile  [-json] [-clear] [name...]\n"+
			"                                show or set who this Mac is for; targets with profiles follow it\n")
}

// initDone is what init wrote, for the app.
type initDone struct {
	starter.Result
	Profiles []string `json:"profiles"`
}

// runInit writes the starter config, puts the packages of other profiles'
// sections on the skip list, and saves this Mac's profiles. It installs
// nothing: plan and apply come next.
func runInit(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := newFlags("init", stderr)
	profile := flags.String("profile", "", "who this Mac is for, comma-separated")
	role := flags.String("role", "", "what this Mac is for, such as work or personal")
	dir := flags.String("dir", "", "where to write the config; default ~/.config/"+name)
	fromMac := flags.Bool("from-mac", false, "also keep the apps this Mac has installed")
	force := flags.Bool("force", false, "replace files that are there")
	asJSON := flags.Bool("json", false, "machine-readable output")
	list := flags.Bool("list", false, "show the profiles and roles")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := noOperands("init", flags); err != nil {
		return err
	}
	if *list {
		return writeProfiles(stdout, *asJSON)
	}
	if *dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		*dir = filepath.Join(home, ".config", name)
	}
	if *role != "" && !config.IsProfile(*role) {
		return fmt.Errorf("role %q must be kebab-case, such as %s", *role, strings.Join(starter.Roles, " or "))
	}
	profiles := splitList(*profile)
	for _, p := range profiles {
		if !config.IsProfile(p) {
			return fmt.Errorf("profile %q must be kebab-case, such as developer or work", p)
		}
	}
	var captured []byte
	if *fromMac {
		var err error
		runner := installerRunner(stdin, stderr)
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		if captured, err = packages.New(runner).Capture(ctx, config.Target{}); err != nil {
			fmt.Fprintln(stderr, "not keeping this Mac's apps:", err)
		}
	}
	res, err := starter.Write(starter.Options{Dir: *dir, Profiles: profiles, Captured: captured, Force: *force})
	if err != nil {
		return err
	}
	if err := addSkips(res.Skip); err != nil {
		return err
	}
	if *role != "" {
		profiles = append(profiles, *role)
	}
	if err := config.WriteProfiles(config.ProfilesPath(), profiles); err != nil {
		return err
	}
	if profiles, err = config.ReadProfiles(config.ProfilesPath()); err != nil {
		return err
	}
	if *asJSON {
		return writeJSON(stdout, initDone{res, profiles})
	}
	for _, f := range res.Files {
		fmt.Fprintln(stdout, "wrote", f)
	}
	fmt.Fprintf(stdout, "this Mac is for %s; %d packages of other profiles are on its skip list\n",
		strings.Join(profiles, ", "), len(res.Skip))
	if res.Kept > 0 {
		fmt.Fprintf(stdout, "kept %d packages this Mac has, under From this Mac\n", res.Kept)
	}
	_, err = fmt.Fprintf(stdout, "next: %s plan -config %s, then apply\n", name, res.Config)
	return err
}

// addSkips adds resources to this machine's skip list.
func addSkips(resources []string) error {
	path := config.SkipPath()
	if path == "" {
		return errors.New("no home folder to keep the skip list in")
	}
	list, ignored, err := config.ReadSkip(path)
	if err != nil {
		return err
	}
	// WriteSkip would drop the ignored lines, so keep them for the user to fix.
	return config.WriteSkip(path, append(append(list, ignored...), resources...))
}

func writeProfiles(w io.Writer, asJSON bool) error {
	if asJSON {
		return writeJSON(w, struct {
			Profiles []starter.Profile `json:"profiles"`
			Roles    []string          `json:"roles"`
		}{starter.Profiles, starter.Roles})
	}
	for _, p := range starter.Profiles {
		fmt.Fprintf(w, "%-10s %s\n", p.Name, p.About)
	}
	_, err := fmt.Fprintf(w, "roles: %s\n", strings.Join(starter.Roles, ", "))
	return err
}

// runProfile shows this Mac's profiles, or with names replaces them. A
// target with profiles applies only on a Mac with one of them; a Mac
// without profiles gets every target.
func runProfile(args []string, _ io.Reader, stdout, stderr io.Writer) error {
	flags := newFlags("profile", stderr)
	asJSON := flags.Bool("json", false, "machine-readable output")
	clear := flags.Bool("clear", false, "drop every profile, so every target applies")
	if err := flags.Parse(args); err != nil {
		return err
	}
	path := config.ProfilesPath()
	if path == "" {
		return errors.New("no home folder to keep the profiles in")
	}
	names := flags.Args()
	if err := rejectTrailingFlags("profile", names); err != nil {
		return err
	}
	for _, n := range names {
		if !config.IsProfile(n) {
			return fmt.Errorf("profile %q must be kebab-case, such as developer or work", n)
		}
	}
	if len(names) > 0 || *clear {
		if err := config.WriteProfiles(path, names); err != nil {
			return err
		}
	}
	list, err := config.ReadProfiles(path)
	if err != nil {
		return err
	}
	if *asJSON {
		return writeJSON(stdout, append([]string{}, list...))
	}
	for _, p := range list {
		if _, err := fmt.Fprintln(stdout, p); err != nil {
			return err
		}
	}
	return nil
}

// splitList cuts a comma-separated flag into its names.
func splitList(s string) []string {
	var out []string
	for p := range strings.SplitSeq(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
