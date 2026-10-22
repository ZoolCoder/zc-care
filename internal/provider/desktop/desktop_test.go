package desktop

import (
	"context"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/sh"
)

type machine struct {
	p      Provider
	r      *sh.Fake
	t      config.Target
	saver  string
	readSS string
}

// setup is a machine with the wallpaper, and a page loading a font, on disk;
// the saver installed when saver is true; and nothing pointed at either yet.
func setup(t *testing.T, saver bool) machine {
	t.Helper()
	root := t.TempDir()
	home, art := filepath.Join(root, "home"), filepath.Join(root, "art dir")
	for _, dir := range []string{art, filepath.Join(home, "Library/Screen Savers")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	tg := config.Target{Name: "look", Provider: "desktop",
		Wallpaper: filepath.Join(art, "wall.png"), Screensaver: filepath.Join(art, "index.html")}
	files := map[string]string{tg.Wallpaper: "", tg.Screensaver: "<style>@font-face{src:url(fonts/a.woff2)}</style>",
		filepath.Join(art, "fonts/a.woff2"): "FONT"}
	for f, body := range files {
		if err := os.MkdirAll(filepath.Dir(f), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	saverDir := filepath.Join(home, "Library/Screen Savers", Saver)
	if saver {
		if err := os.MkdirAll(filepath.Join(saverDir, "Contents"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(saverDir, "Contents/Info.plist"), []byte("original"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	tg.Accent = "blue"
	readSS := sh.Line("plutil", "-extract", defaultURLKey, "raw", "-o", "-", filepath.Join(saverDir, "Contents/Info.plist"))
	p := Provider{home: home, system: filepath.Join(root, "system")}
	r := &sh.Fake{Out: map[string]string{
		store(p, "read", tg.Wallpaper): "1 3\n",
		readSS:                         "http://www.google.com/\n",
		sh.Line("plutil", "-convert", "xml1", "-o", "-", filepath.Join(saverDir, "Contents/Info.plist")): emptyPlist,
		sh.Line("defaults", "read", "-g", "AppleAccentColor"):                                            "5\n",
		store(p, "write", tg.Wallpaper):                                                                  "1 3\n",
	}}
	r.OnRun = fakePlutil
	p.r = r
	return machine{p, r, tg, saverDir, readSS}
}

// fakePlutil makes `plutil -convert xml1 -o OUT IN` write OUT, as plutil does.
func fakePlutil(line string) {
	const prefix = "plutil -convert xml1 -o "
	if !strings.HasPrefix(line, prefix) {
		return
	}
	// The temp input has no spaces; the output path may.
	i := strings.LastIndex(line, " ")
	out, in := line[len(prefix):i], line[i+1:]
	b, _ := os.ReadFile(in)
	_ = os.WriteFile(out, b, 0o600)
}

// store is the store.js command line for mode and picture.
func store(p Provider, mode, picture string) string {
	return sh.Line("osascript", "-l", "JavaScript", "-e", storeJS, mode, p.store(), fileURL(picture))
}

// page is what the saver should hold for setup's page: the page as a data URL,
// its font inlined.
func page() string {
	html := "<style>@font-face{src:url(data:font/woff2;base64," + base64.StdEncoding.EncodeToString([]byte("FONT")) + ")}</style>"
	return "data:text/html;base64," + base64.StdEncoding.EncodeToString([]byte(html))
}

func TestPlanSetsWallpaperAndPointsTheSaver(t *testing.T) {
	m := setup(t, true)
	ctx := context.Background()
	actions, err := m.p.Plan(ctx, m.t)
	if err != nil || len(actions) != 3 {
		t.Fatalf("plan %+v %v", actions, err)
	}
	for _, a := range actions {
		if a.Op != plan.OpUpdate {
			t.Fatalf("%s is %s", a.Resource, a.Op)
		}
		if err := a.Do(ctx); err != nil {
			t.Fatal(err)
		}
	}
	want := []string{
		sh.Line("osascript", "-e", "on run argv", "-e", `tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)`, "-e", "end run", m.t.Wallpaper),
		sh.Line("killall", "WallpaperAgent"),
		sh.Line("plutil", "-convert", "xml1", "-o", "OUT", "TMP"),
		sh.Line("codesign", "--force", "--sign", "-", m.saver),
		sh.Line("defaults", "write", "-g", "AppleAccentColor", "-int", "4"),
		sh.Line("defaults", "write", "-g", "AppleHighlightColor", "-string", "0.698039 0.843137 1.000000 Blue"),
	}
	ran := strings.Join(m.r.Ran, "\n")
	if tmp := tempPlist.FindString(ran); tmp != "" {
		ran = strings.Replace(ran, tmp, "TMP", 1)
	}
	ran = savedPlist.ReplaceAllString(ran, "-o OUT")
	if ran != strings.Join(want, "\n") {
		t.Fatalf("ran\n%s", ran)
	}
}

var savedPlist = regexp.MustCompile(`-o .*\.Info\.plist\.zc-care-\d+`)

var tempPlist = regexp.MustCompile(`\S*zc-care-saver-\d+\.plist`)

func TestSaverPageGoesThroughATempFileNotTheArguments(t *testing.T) {
	m := setup(t, true)
	plist := filepath.Join(m.saver, "Contents/Info.plist")
	m.r.Out[sh.Line("plutil", "-convert", "xml1", "-o", "-", plist)] = plistWith(
		"<key>CFBundleName</key>\n\t<string>x</string>\n\t<key>Scale</key>\n\t<real>1.0</real>\n\t<key>Built</key>\n\t<date>2026-01-02T03:04:05Z</date>")
	var written string
	m.r.OnRun = func(line string) {
		if f := strings.Fields(line); len(f) > 1 && f[1] == "-convert" {
			b, _ := os.ReadFile(f[len(f)-1])
			written = string(b)
		}
		fakePlutil(line)
	}
	if err := m.p.setSaverPage(context.Background(), plist, "data:big&<x>"); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"<key>" + defaultURLKey + "</key>\n\t<string>data:big&amp;&lt;x&gt;</string>",
		"<real>1.0</real>", "<date>2026-01-02T03:04:05Z</date>", "<string>x</string>",
	} {
		if !strings.Contains(written, want) {
			t.Fatalf("temp file lacks %q:\n%s", want, written)
		}
	}
	for _, line := range m.r.Ran {
		if strings.Contains(line, "data:big") {
			t.Fatalf("page in arguments: %s", line)
		}
	}
}

func TestSaverPageReplacesTheExistingAddress(t *testing.T) {
	doc, err := withPlistString(plistWith("<key>"+defaultURLKey+"</key>\n\t<string>http://old/</string>\n\t<key>Z</key>\n\t<true/>"), defaultURLKey, "data:new")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(doc, "http://old/") || strings.Count(doc, "<key>"+defaultURLKey+"</key>") != 1 || !strings.Contains(doc, "<string>data:new</string>") {
		t.Fatalf("plist:\n%s", doc)
	}
	if _, err := withPlistString("<plist><array/></plist>", defaultURLKey, "x"); err == nil {
		t.Fatal("a plist without a top-level dict was accepted")
	}
}

// plistWith is an XML plist whose top-level dict holds entries.
func plistWith(entries string) string {
	return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n\t" + entries + "\n</dict>\n</plist>\n"
}

var emptyPlist = plistWith("")

func TestStoppedWallpaperAgentIsNotAnError(t *testing.T) {
	m := setup(t, true)
	m.r.Err = map[string]error{sh.Line("killall", "WallpaperAgent"): errors.New("no process found")}
	actions, err := m.p.Plan(context.Background(), m.t)
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range actions {
		if a.Resource != "wallpaper" {
			continue
		}
		if err := a.Do(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
}

func TestInPlaceWhenEveryDesktopAndTheSaverMatch(t *testing.T) {
	m := setup(t, true)
	m.r.Out[store(m.p, "read", m.t.Wallpaper)] = "3 3\n"
	m.r.Out[m.readSS] = page() + "\n"
	m.r.Out[sh.Line("defaults", "read", "-g", "AppleAccentColor")] = "4\n"
	ctx := context.Background()
	if actions, err := m.p.Plan(ctx, m.t); err != nil || len(actions) != 0 {
		t.Fatalf("plan %+v %v", actions, err)
	}
	live, err := m.p.Measure(ctx, m.t)
	if err != nil || live.InPlace != 3 || live.Declared != 3 || live.Summary != "wallpaper in place, screensaver in place, accent in place" {
		t.Fatalf("live %+v %v", live, err)
	}
}

func TestMissingSaverOrFilesAreManual(t *testing.T) {
	m := setup(t, false)
	_ = os.Remove(m.t.Wallpaper)
	m.t.Accent = ""
	actions, err := m.p.Plan(context.Background(), m.t)
	if err != nil || len(actions) != 2 {
		t.Fatalf("plan %+v %v", actions, err)
	}
	if a := actions[0]; a.Op != plan.OpManual || a.Resource != "wallpaper" || !strings.Contains(a.Detail, "no picture at") {
		t.Fatalf("wallpaper %+v", a)
	}
	if a := actions[1]; a.Op != plan.OpManual || a.Resource != "webviewscreensaver" || !strings.Contains(a.Detail, "build-saver.sh") {
		t.Fatalf("saver %+v", a)
	}
}

func TestSystemWideSaverCounts(t *testing.T) {
	m := setup(t, false)
	saver := filepath.Join(m.p.system, "Screen Savers", Saver)
	if err := os.MkdirAll(saver, 0o755); err != nil {
		t.Fatal(err)
	}
	m.r.Out[sh.Line("plutil", "-extract", defaultURLKey, "raw", "-o", "-", filepath.Join(saver, "Contents/Info.plist"))] = page()
	m.t.Accent = ""
	items, err := m.p.Items(context.Background(), m.t)
	if err != nil || len(items) != 2 || items[1].Kind != "screensaver" || items[1].State != "in place" {
		t.Fatalf("items %+v %v", items, err)
	}
}

func TestOnlyTheKeysSetAreRead(t *testing.T) {
	m := setup(t, true)
	m.t.Screensaver, m.t.Accent = "", ""
	items, err := m.p.Items(context.Background(), m.t)
	if err != nil || len(items) != 1 || items[0].Kind != "wallpaper" {
		t.Fatalf("items %+v %v", items, err)
	}
	if progs := m.p.Programs(m.t); strings.Join(progs, " ") != "osascript killall" {
		t.Fatalf("programs %v", progs)
	}
}

func TestFailedSigningPutsThePlistBack(t *testing.T) {
	m := setup(t, true)
	plist := filepath.Join(m.saver, "Contents/Info.plist")
	sign := sh.Line("codesign", "--force", "--sign", "-", m.saver)
	m.r.Err = map[string]error{sign: errors.New("codesign failed")}
	actions, err := m.p.Plan(context.Background(), m.t)
	if err != nil {
		t.Fatal(err)
	}
	var saver plan.Action
	for _, a := range actions {
		if a.Resource == "screensaver" {
			saver = a
		}
	}
	if saver.Digest == "" {
		t.Fatal("screensaver action has no digest")
	}
	if err := saver.Do(context.Background()); err == nil || !strings.Contains(err.Error(), "codesign failed") {
		t.Fatalf("err %v", err)
	}
	if b, _ := os.ReadFile(plist); string(b) != "original" {
		t.Fatalf("plist left changed: %q", b)
	}
	if entries, _ := os.ReadDir(filepath.Dir(plist)); len(entries) != 1 {
		t.Fatalf("temp file left behind: %v", entries)
	}
}

func TestSaverPageFillsAnEmptyStringElement(t *testing.T) {
	doc, err := withPlistString(plistWith("<key>"+defaultURLKey+"</key>\n\t<string/>"), defaultURLKey, "data:new")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(doc, "<key>"+defaultURLKey+"</key>") != 1 || !strings.Contains(doc, "<string>data:new</string>") {
		t.Fatalf("plist:\n%s", doc)
	}
}

func TestMediaType(t *testing.T) {
	for name, want := range map[string]string{
		"a.woff2": "font/woff2", "x/b.PNG": "image/png", "c.css": "text/css; charset=utf-8", "d.unknownext": "application/octet-stream",
	} {
		if got := mediaType(name); got != want {
			t.Errorf("mediaType(%q) = %q, want %q", name, got, want)
		}
	}
}
