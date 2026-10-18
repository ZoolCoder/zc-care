// Package desktop sets how a Mac looks: the desktop picture, the page the
// WebViewScreenSaver screen saver shows, and the accent colour.
//
// The picture lives in the wallpaper store, where every Space on every display
// keeps its own; System Events reaches only the Spaces in view, so store.js
// reads and rewrites the store itself. The page goes into the saver's own
// Info.plist as its default address, because macOS keeps the saver's
// preferences in a container no terminal may open, and the sandboxed saver
// cannot read files outside its bundle.
package desktop

import (
	"context"
	_ "embed"
	"encoding/base64"
	"fmt"
	"mime"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/zoolcoder/zc-care/internal/config"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/provider"
	"github.com/zoolcoder/zc-care/internal/sh"
)

// Saver is the screen saver bundle the screensaver key needs, built and
// installed by assets/screensaver/build-saver.sh.
const Saver = "WebViewScreenSaver.saver"

// defaultURLKey is the Info.plist key holding the page the saver shows while
// its own list of pages is empty.
const defaultURLKey = "WVSSDefaultAddressURL"

//go:embed store.js
var storeJS string

// accents are the AppleAccentColor number and AppleHighlightColor value of
// each accent colour, as System Settings writes them.
var accents = map[string][2]string{
	"red":      {"0", "1.000000 0.733333 0.721569 Red"},
	"orange":   {"1", "1.000000 0.874510 0.701961 Orange"},
	"yellow":   {"2", "1.000000 0.937255 0.690196 Yellow"},
	"green":    {"3", "0.752941 0.964706 0.678431 Green"},
	"blue":     {"4", "0.698039 0.843137 1.000000 Blue"},
	"purple":   {"5", "0.968627 0.831373 1.000000 Purple"},
	"pink":     {"6", "1.000000 0.749020 0.823529 Pink"},
	"graphite": {"-1", "0.847059 0.847059 0.862745 Graphite"},
}

type Provider struct {
	r sh.Runner
	// home holds Library; Saver may also sit in system, the shared Library.
	home, system string
}

func New(r sh.Runner) Provider {
	home, _ := os.UserHomeDir()
	return Provider{r: r, home: home, system: "/Library"}
}

// look is what the machine shows now, for each key the target sets.
type look struct {
	wallpaper, screensaver, accent state
	// saver is the installed saver bundle, and page the page as a data URL,
	// when the screensaver key is set.
	saver, page string
}

// state is one key's reading: its item state and what to say about it.
type state struct {
	set    bool
	state  string
	detail string
	// resource names what a missing state's MANUAL step is about, when that
	// is not the key itself.
	resource string
}

func (p Provider) read(ctx context.Context, t config.Target) (look, error) {
	var l look
	if t.Wallpaper != "" {
		s, err := p.readWallpaper(ctx, t.Wallpaper)
		if err != nil {
			return l, err
		}
		l.wallpaper = s
	}
	if t.Screensaver != "" {
		s, saver, page, err := p.readScreensaver(ctx, t.Screensaver)
		if err != nil {
			return l, err
		}
		l.screensaver, l.saver, l.page = s, saver, page
	}
	if t.Accent != "" {
		l.accent = p.readAccent(ctx, t.Accent)
	}
	return l, nil
}

func (p Provider) store() string {
	return filepath.Join(p.home, "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
}

func fileURL(path string) string { return (&url.URL{Scheme: "file", Path: path}).String() }

func (p Provider) runStore(ctx context.Context, mode, picture string) ([]byte, error) {
	return p.r.Output(ctx, "osascript", "-l", "JavaScript", "-e", storeJS, mode, p.store(), fileURL(picture))
}

func (p Provider) readWallpaper(ctx context.Context, want string) (state, error) {
	if _, err := os.Stat(want); err != nil {
		return state{set: true, state: provider.Missing, detail: "no picture at " + want + "; render it first"}, nil
	}
	out, err := p.runStore(ctx, "read", want)
	if err != nil {
		return state{}, fmt.Errorf("read desktop pictures: %w", err)
	}
	var shows, spaces int
	if _, err := fmt.Sscan(string(out), &shows, &spaces); err != nil {
		return state{}, fmt.Errorf("read desktop pictures: %q", out)
	}
	if spaces > 0 && shows == spaces {
		return state{set: true, state: provider.InPlace, detail: fmt.Sprintf("on every desktop, %d Spaces", spaces)}, nil
	}
	return state{set: true, state: provider.Differs, detail: fmt.Sprintf("%d of %d Spaces show another picture", spaces-shows, spaces)}, nil
}

func (p Provider) readScreensaver(ctx context.Context, path string) (state, string, string, error) {
	if _, err := os.Stat(path); err != nil {
		return state{set: true, state: provider.Missing, detail: "no page at " + path}, "", "", nil
	}
	saver := p.installedSaver()
	if saver == "" {
		return state{set: true, state: provider.Missing, resource: "webviewscreensaver",
			detail: "install the saver: run assets/screensaver/build-saver.sh from zc-care (needs Xcode)"}, "", "", nil
	}
	page, err := dataURL(path)
	if err != nil {
		return state{}, "", "", err
	}
	// A fresh build holds the upstream default address, so it differs.
	out, err := p.r.Output(ctx, "plutil", "-extract", defaultURLKey, "raw", "-o", "-", infoPlist(saver))
	if err == nil && strings.TrimSpace(string(out)) == page {
		return state{set: true, state: provider.InPlace, detail: "WebViewScreenSaver shows it"}, saver, page, nil
	}
	return state{set: true, state: provider.Differs, detail: "WebViewScreenSaver shows another page"}, saver, page, nil
}

// readAccent compares the accent number; with none set, macOS shows multicolour.
func (p Provider) readAccent(ctx context.Context, want string) state {
	out, err := p.r.Output(ctx, "defaults", "read", "-g", "AppleAccentColor")
	if err == nil && strings.TrimSpace(string(out)) == accents[want][0] {
		return state{set: true, state: provider.InPlace, detail: "macOS accent is " + want}
	}
	return state{set: true, state: provider.Differs, detail: "macOS shows another accent colour"}
}

func infoPlist(saver string) string { return filepath.Join(saver, "Contents/Info.plist") }

func (p Provider) installedSaver() string {
	for _, lib := range []string{filepath.Join(p.home, "Library"), p.system} {
		saver := filepath.Join(lib, "Screen Savers", Saver)
		if info, err := os.Stat(saver); err == nil && info.IsDir() {
			return saver
		}
	}
	return ""
}

// localRef is a relative url() in the page's CSS, such as a font beside it.
var localRef = regexp.MustCompile(`url\(([\w./-]+\.\w+)\)`)

// dataURL is the page as one data URL, with the files its CSS loads from its
// folder inlined, so the saver needs no file access.
func dataURL(path string) (string, error) {
	page, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	var readErr error
	page = localRef.ReplaceAllFunc(page, func(ref []byte) []byte {
		name := string(localRef.FindSubmatch(ref)[1])
		b, err := os.ReadFile(filepath.Join(filepath.Dir(path), name))
		if err != nil {
			readErr = err
			return ref
		}
		return []byte("url(data:" + mediaType(name) + ";base64," + base64.StdEncoding.EncodeToString(b) + ")")
	})
	if readErr != nil {
		return "", fmt.Errorf("inline into %s: %w", filepath.Base(path), readErr)
	}
	return "data:text/html;base64," + base64.StdEncoding.EncodeToString(page), nil
}

func mediaType(name string) string {
	if filepath.Ext(name) == ".woff2" {
		return "font/woff2"
	}
	if t := mime.TypeByExtension(filepath.Ext(name)); t != "" {
		return t
	}
	return "application/octet-stream"
}

// Plan sets what differs. A missing file or saver is MANUAL: rendering art and
// installing software are steps a person takes.
func (p Provider) Plan(ctx context.Context, t config.Target) ([]plan.Action, error) {
	l, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	var actions []plan.Action
	switch l.wallpaper.state {
	case provider.Missing:
		actions = append(actions, manual(t, "wallpaper", l.wallpaper))
	case provider.Differs:
		actions = append(actions, plan.Action{Op: plan.OpUpdate, Target: t.Name, Resource: "wallpaper",
			Detail: "set " + filepath.Base(t.Wallpaper) + " on every desktop and Space",
			Do: func(ctx context.Context) error {
				// System Events records the Spaces in view, so a new Mac's store
				// has them; the store rewrite then reaches every other Space.
				if err := p.r.Run(ctx, "osascript", "-e", "on run argv",
					"-e", `tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)`,
					"-e", "end run", t.Wallpaper); err != nil {
					return err
				}
				if _, err := p.runStore(ctx, "write", t.Wallpaper); err != nil {
					return err
				}
				// The agent draws from the store only when it starts.
				return p.r.Run(ctx, "killall", "WallpaperAgent")
			}})
	}
	switch l.screensaver.state {
	case provider.Missing:
		actions = append(actions, manual(t, "screensaver", l.screensaver))
	case provider.Differs:
		actions = append(actions, plan.Action{Op: plan.OpUpdate, Target: t.Name, Resource: "screensaver",
			Detail: "show " + filepath.Base(t.Screensaver) + " in WebViewScreenSaver; pick it once in System Settings, Screen Saver",
			Do: func(ctx context.Context) error {
				if err := p.r.Run(ctx, "plutil", "-replace", defaultURLKey, "-string", l.page, infoPlist(l.saver)); err != nil {
					return err
				}
				// Editing Info.plist breaks the bundle's seal; sign it again, ad hoc as built.
				return p.r.Run(ctx, "codesign", "--force", "--sign", "-", l.saver)
			}})
	}
	if l.accent.state == provider.Differs {
		a := accents[t.Accent]
		actions = append(actions, plan.Action{Op: plan.OpUpdate, Target: t.Name, Resource: "accent",
			Detail: "set the macOS accent colour to " + t.Accent + "; apps show it once they restart",
			Do: func(ctx context.Context) error {
				if err := p.r.Run(ctx, "defaults", "write", "-g", "AppleAccentColor", "-int", a[0]); err != nil {
					return err
				}
				return p.r.Run(ctx, "defaults", "write", "-g", "AppleHighlightColor", "-string", a[1])
			}})
	}
	return actions, nil
}

func manual(t config.Target, key string, s state) plan.Action {
	if s.resource != "" {
		key = s.resource
	}
	return plan.Action{Op: plan.OpManual, Target: t.Name, Resource: key, Detail: s.detail}
}

func (p Provider) Measure(ctx context.Context, t config.Target) (provider.Live, error) {
	items, err := p.Items(ctx, t)
	if err != nil {
		return provider.Live{}, err
	}
	live := provider.Live{Declared: len(items)}
	var parts []string
	for _, i := range items {
		if i.State == provider.InPlace {
			live.InPlace++
		}
		parts = append(parts, i.Kind+" "+i.State)
	}
	live.Summary = strings.Join(parts, ", ")
	return live, nil
}

func (p Provider) Status(ctx context.Context, t config.Target) (string, error) {
	live, err := p.Measure(ctx, t)
	return live.Summary, err
}

// Items is the wallpaper, the screen saver page and the accent colour, as the
// target sets them.
func (p Provider) Items(ctx context.Context, t config.Target) ([]provider.Item, error) {
	l, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	var items []provider.Item
	if l.wallpaper.set {
		items = append(items, provider.Item{Name: filepath.Base(t.Wallpaper), Kind: "wallpaper", State: l.wallpaper.state, Desc: l.wallpaper.detail})
	}
	if l.screensaver.set {
		items = append(items, provider.Item{Name: filepath.Base(t.Screensaver), Kind: "screensaver", State: l.screensaver.state,
			App: "WebViewScreenSaver", Desc: l.screensaver.detail})
	}
	if l.accent.set {
		items = append(items, provider.Item{Name: t.Accent, Kind: "accent", State: l.accent.state, Desc: l.accent.detail})
	}
	return items, nil
}

func (Provider) Programs(t config.Target) []string {
	var progs []string
	if t.Wallpaper != "" {
		progs = append(progs, "osascript", "killall")
	}
	if t.Screensaver != "" {
		progs = append(progs, "plutil", "codesign")
	}
	if t.Accent != "" {
		progs = append(progs, "defaults")
	}
	return progs
}
