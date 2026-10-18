import Foundation

/// The first things to try with a package, from its toolbox page in the
/// manual. A package without an entry shows its manifest comment alone.
public struct Tip: Sendable, Equatable {
    public struct Use: Sendable, Equatable, Hashable {
        public var keys: String
        public var does: String
    }

    public var uses: [Use]
    /// The package's page in the manual's toolbox.
    public var guide: URL?
}

public enum Tips {
    static let toolbox = "https://zoolcoder.github.io/zc-care/toolbox/"

    /// The tip for a package, by its short name: a tapped formula such as
    /// FelixKratz/formulae/sketchybar is sketchybar.
    public static func tip(for item: Item) -> Tip? {
        let short = item.name.split(separator: "/").last.map(String.init)?.lowercased() ?? item.name
        guard let (page, uses) = book[short] else { return nil }
        return Tip(uses: uses.map { Tip.Use(keys: $0.0, does: $0.1) }, guide: URL(string: toolbox + page + ".html"))
    }

    /// Short name: the toolbox page, and the keys and commands it puts first.
    static let book: [String: (String, [(String, String)])] = [
        "ghostty": ("ghostty", [("Cmd+`", "Drop-down quick terminal from any app"),
                                ("Cmd+Shift+C", "Claude Code in a split, continuing this folder"),
                                ("Cmd+1 to Cmd+8", "Jump to a tab")]),
        "tmux": ("tmux", [("dev", "Pick a repo: Claude Code, lazygit and a shell side by side"),
                          ("Ctrl+Space s", "Pick a session with a live preview"),
                          ("Ctrl+Space g", "lazygit in a popup")]),
        "starship": ("starship", [("cd into a repo", "The prompt shows branch, changes, pull request and versions")]),
        "antidote": ("zsh", [("Tab", "Fuzzy completion menu with previews"),
                             ("Esc Esc", "Put sudo in front of the last command"),
                             ("update", "Pull, rebuild, apply and upgrade everything, then run the doctor")]),
        "atuin": ("atuin", [("Ctrl+R", "Search all history; again for this host, session or folder")]),
        "fzf": ("fzf", [("Ctrl+T", "Insert a file path"), ("Alt+C", "cd into a folder"),
                        ("** then Tab", "Fuzzy completion of a path or a process")]),
        "zoxide": ("zoxide", [("z part", "Jump to the most used folder matching part"),
                              ("zi", "Pick among the matches with fzf")]),
        "eza": ("eza", [("ll, la", "Long list, list hidden files"), ("lt3", "A tree three levels deep")]),
        "bat": ("bat", [("bat file", "Show a file with highlighting"), ("man git", "Man pages, highlighted")]),
        "fd": ("fd-ripgrep", [("fd name", "Find files whose name matches")]),
        "ripgrep": ("fd-ripgrep", [("rg text", "Search the repository for text")]),
        "yazi": ("yazi", [("y", "Browse files with previews; q leaves you in that folder")]),
        "jq": ("jq-yq", [("jq . file.json", "Pretty-print JSON"), ("jq -r '.[].name'", "One field of every item")]),
        "yq": ("jq-yq", [("yq '.a.b' file.yaml", "Query YAML"), ("yq -i '.key = \"v\"' file.yaml", "Edit YAML in place")]),
        "mise": ("mise", [("mise use java@21", "Pin a version in this folder"), ("mise ls", "What is installed and active")]),
        "direnv": ("direnv", [("direnv allow", "Trust this folder's .envrc after reading it")]),
        "chezmoi": ("chezmoi", [("zc-care plan -target home", "What would change in your dotfiles")]),
        "git-delta": ("git-tools", [("gd, gds", "Side-by-side diffs, staged or not")]),
        "difftastic": ("git-tools", [("git dft", "A diff that follows the syntax")]),
        "git-absorb": ("git-tools", [("git absorb", "Fixup commits for what is staged")]),
        "lazygit": ("lazygit", [("lazygit", "Git in a terminal UI, in this repository"),
                                ("Ctrl+Space g", "The same in a tmux popup")]),
        "gitleaks": ("gitleaks", [("git commit", "Staged changes are scanned for secrets"),
                                  ("gitleaks git", "Scan a repository's whole history")]),
        "gh": ("gh", [("prc, prv, prl", "Create, open or list pull requests"), ("gh run watch", "Follow a CI run")]),
        "go": ("go", [("go test ./...", "Every test in the module")]),
        "colima": ("containers", [("colima start", "Start the Docker engine"), ("dps", "Containers with status and ports")]),
        "lazydocker": ("containers", [("lazydocker", "Containers, logs and images in a terminal UI")]),
        "k9s": ("containers", [("k9s", "A cluster in a terminal UI")]),
        "pgcli": ("postgresql", [("pgcli dbname", "PostgreSQL with completion and highlighting")]),
        "btop": ("system", [("btop", "Everything the Mac is doing")]),
        "macmon": ("system", [("macmon", "Power and temperatures")]),
        "dust": ("system", [("dust", "Which folders use the disk")]),
        "raycast": ("raycast", [("Raycast hotkey", "Open Raycast"), ("Open Repo", "Pick a repository and open it")]),
        "karabiner-elements": ("karabiner", [("Caps Lock", "Escape when tapped, Hyper when held"),
                                             ("Hyper+T, Hyper+V, Hyper+B", "Ghostty, VS Code, Chrome")]),
        "sketchybar": ("sketchybar", [("zccare item", "ZC Care's open items; click it for the panel")]),
        "visual-studio-code": ("vscode", [("Hyper+V", "Open VS Code")]),
        "google-chrome": ("chrome", [("Hyper+B", "Open Chrome")]),
    ]
}
