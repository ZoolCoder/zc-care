package dotfiles

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/sh"
)

func target(t *testing.T) config.Target {
	return config.Target{Name: "dots", Provider: "dotfiles", Source: t.TempDir(), Destination: "/home/me"}
}

func TestPlanReadsChezmoiStatus(t *testing.T) {
	tg := target(t)
	base := "chezmoi --source " + tg.Source + " --no-tty --destination /home/me "
	r := &sh.Fake{
		Programs: []string{"chezmoi"},
		Out: map[string]string{
			base + "status --exclude dirs":            " A .zshrc\nMM .gitconfig\n D .old\n R install-tools.sh\n",
			base + "managed --include files,symlinks": ".zshrc\n.gitconfig\n.tmux.conf\n",
		},
	}
	p := New(r)
	actions, err := p.Plan(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, a := range actions {
		got = append(got, string(a.Op)+" "+a.Resource+" ("+a.Detail+")")
	}
	want := []string{
		"CREATE .zshrc (add)",
		"UPDATE .gitconfig (update; changed outside chezmoi, apply overwrites it)",
		"DELETE .old (remove)",
		"UPDATE install-tools.sh (run script)",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("plan\n%s", strings.Join(got, "\n"))
	}
	// Overwriting an outside edit and running a script need confirmation; a
	// plain add or update does not.
	for n, destructive := range []bool{false, true, false, true} {
		if actions[n].Destructive != destructive {
			t.Fatalf("%s destructive = %v", actions[n].Resource, actions[n].Destructive)
		}
	}
	if err := actions[1].Do(context.Background()); err != nil {
		t.Fatal(err)
	}
	if r.Ran[0] != base+"apply --force --recursive=false "+filepath.Join("/home/me", ".gitconfig") {
		t.Fatalf("ran %v", r.Ran)
	}
	live, err := p.Measure(context.Background(), tg)
	if err != nil || live.InPlace != 1 || live.Declared != 3 || live.Summary != "1 of 3 dotfiles in place, 2 script(s) to run" {
		t.Fatalf("live %+v %v", live, err)
	}
	items, err := p.Items(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	got = nil
	for _, i := range items {
		got = append(got, strings.Join([]string{i.Kind, i.Name, i.State, i.App, i.Desc}, "|"))
	}
	want = []string{
		"dotfile|.zshrc|missing|zsh|",
		"dotfile|.gitconfig|differs|git|changed outside chezmoi",
		"dotfile|.tmux.conf|in place|tmux|",
		"script|.old|differs||remove",
		"script|install-tools.sh|differs||run script",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("items\n%s", strings.Join(got, "\n"))
	}
}

func TestAppOf(t *testing.T) {
	for path, want := range map[string]string{
		".config/ghostty/config":                              "ghostty",
		".config/starship.toml":                               "starship",
		".local/share/atuin/init.nu":                          "atuin",
		"Library/Application Support/Code/User/settings.json": "Code",
		"AppData/Roaming/alacritty/alacritty.toml":            "alacritty",
		"Library/LaunchAgents/local.ssh-add-enclave.plist":    "launchd",
		".zshrc":            "zsh",
		".zprofile":         "zsh",
		".gitconfig":        "git",
		".gitignore_global": "git",
		".tmux.conf":        "tmux",
		".ssh/config":       "ssh",
		".vimrc":            "vim",
	} {
		if got := appOf(path); got != want {
			t.Errorf("appOf(%q) = %q, want %q", path, got, want)
		}
	}
}

func TestWithParents(t *testing.T) {
	got := withParents("/h", ".config/app/app.toml")
	want := []string{filepath.Join("/h", ".config"), filepath.Join("/h", ".config", "app"), filepath.Join("/h", ".config", "app", "app.toml")}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatal(got)
	}
}

func TestModeIsPassedToChezmoi(t *testing.T) {
	tg := config.Target{Source: "/s", Mode: "symlink"}
	if got := strings.Join(args(tg, "status"), " "); got != "--source /s --no-tty --mode symlink status" {
		t.Fatal(got)
	}
}

func TestMissingChezmoiOrSourceIsManual(t *testing.T) {
	tg := target(t)
	for name, c := range map[string]struct {
		r  *sh.Fake
		tg config.Target
	}{
		"no chezmoi": {&sh.Fake{}, tg},
		"no source":  {&sh.Fake{Programs: []string{"chezmoi"}}, config.Target{Name: "dots", Source: filepath.Join(tg.Source, "nope")}},
	} {
		actions, err := New(c.r).Plan(context.Background(), c.tg)
		if err != nil || len(actions) != 1 || actions[0].Op != plan.OpManual {
			t.Errorf("%s: %+v %v", name, actions, err)
		}
	}
}

// TestWithRealChezmoi runs the whole cycle against chezmoi in temp
// directories. It never touches the real home directory.
func TestWithRealChezmoi(t *testing.T) {
	if _, err := exec.LookPath("chezmoi"); err != nil {
		t.Skip("chezmoi is not on PATH")
	}
	src, home := t.TempDir(), t.TempDir()
	// chezmoi reads its config and state from the home directory.
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	write(t, filepath.Join(src, "dot_zshrc"), "export EDITOR=vim\n")
	write(t, filepath.Join(src, "dot_config", "app", "app.toml"), "x = 1\n")
	write(t, filepath.Join(home, ".zshrc"), "export EDITOR=nano\n")

	ctx := context.Background()
	p := New(sh.Exec{})
	tg := config.Target{Name: "dots", Source: src, Destination: home}
	actions, err := p.Plan(ctx, tg)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]plan.Op{}
	for _, a := range actions {
		got[a.Resource] = a.Op
	}
	if len(got) != 2 || got[".zshrc"] != plan.OpUpdate || got[".config/app/app.toml"] != plan.OpCreate {
		t.Fatalf("plan %v", got)
	}
	for _, a := range actions {
		if err := a.Do(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if again, err := p.Plan(ctx, tg); err != nil || len(again) != 0 {
		t.Fatalf("after apply %+v %v", again, err)
	}
	if b, _ := os.ReadFile(filepath.Join(home, ".zshrc")); string(b) != "export EDITOR=vim\n" {
		t.Fatalf(".zshrc %q", b)
	}
	live, err := p.Measure(ctx, tg)
	if err != nil || live.InPlace != 2 || live.Declared != 2 {
		t.Fatalf("live %+v %v", live, err)
	}
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestDigestHashesTheSourceFileOnly(t *testing.T) {
	tg := target(t)
	base := "chezmoi --source " + tg.Source + " --no-tty --destination /home/me "
	file := "/home/me/.zshrc"
	src := filepath.Join(tg.Source, "dot_zshrc")
	if err := os.WriteFile(src, []byte("export A=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := &sh.Fake{Out: map[string]string{}, Err: map[string]error{}}
	p := New(r)
	ctx := context.Background()
	if got := p.digest(ctx, tg, file); got != "" {
		t.Fatalf("digest %q with nothing to read", got)
	}
	r.Out[base+"source-path "+file] = src + "\n"
	want := p.digest(ctx, tg, file)
	r.Out[base+"diff --recursive=false "+file] = "+export A=1\n"
	if want == "" || p.digest(ctx, tg, file) != want {
		t.Fatalf("digest %q changed when chezmoi diff did", want)
	}
}

func TestRestoreLinkReplacesAFileInOneRename(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "sub", ".zshrc")
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("applied\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := restoreLink(file, "/elsewhere/zshrc"); err != nil {
		t.Fatal(err)
	}
	if got, err := os.Readlink(file); err != nil || got != "/elsewhere/zshrc" {
		t.Fatalf("link %q, %v", got, err)
	}
	if entries, _ := os.ReadDir(filepath.Dir(file)); len(entries) != 1 {
		t.Fatalf("temp link left behind: %v", entries)
	}
}
