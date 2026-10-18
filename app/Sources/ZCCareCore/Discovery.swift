import Foundation

/// Where the CLI and its config are. An app opened from Finder gets launchd's
/// bare environment, not the shell's, so both are looked for.
public enum Discovery {
    /// The login shell's environment, for PATH: Homebrew, mise and the CLI
    /// live where only the shell's profile says. mise's own variables from
    /// a terminal that opened the app go: they describe that shell's PATH,
    /// not this one.
    public static func loginEnvironment(runner: any Runner = ProcessRunner(timeout: 30),
                                        base: [String: String] = ProcessInfo.processInfo.environment) async -> [String: String] {
        let base = base.filter { !$0.key.hasPrefix("MISE_") && !$0.key.hasPrefix("__MISE_") }
        let shell = base["SHELL"] ?? "/bin/zsh"
        guard let r = try? await runner.run(shell, ["-l", "-c", "env -0"], env: base), r.status == 0 else {
            return withHomebrew(base)
        }
        return withHomebrew(parseEnv(r.stdout).merging(base) { login, _ in login })
    }

    /// A new Mac's profile names Homebrew only once the dotfiles are in,
    /// and the first install, picked in ZC Care, comes before them.
    static func withHomebrew(_ env: [String: String]) -> [String: String] {
        var env = env
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !path.split(separator: ":").contains("/opt/homebrew/bin") {
            env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:" + path
        }
        return env
    }

    static func parseEnv(_ data: Data) -> [String: String] {
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let s = String(decoding: entry, as: UTF8.self)
            if let eq = s.firstIndex(of: "=") {
                env[String(s[..<eq])] = String(s[s.index(after: eq)...])
            }
        }
        return env
    }

    /// The zc-care the app carries, so app and CLI match; then the
    /// first on PATH, then where `make install` puts it.
    public static func binary(env: [String: String], home: String,
                              bundled: String? = Bundle.main.executableURL?.deletingLastPathComponent().path,
                              isExecutable: (String) -> Bool = FileManager.default.isExecutableFile) -> String? {
        let dirs = [bundled].compactMap { $0 } + (env["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home + "/.local/bin", "/opt/homebrew/bin"]
        return dirs.map { $0 + "/zc-care" }.first(where: isExecutable)
    }

    /// The config the owner chose in the app, then the CLI's own lookup:
    /// $ZC_CARE_CONFIG, then ~/.config/zc-care.
    public static func config(chosen: String?, env: [String: String], home: String,
                              exists: (String) -> Bool = FileManager.default.fileExists) -> String? {
        let fallback = home + "/.config/zc-care/zc-care.yaml"
        return [chosen, env["ZC_CARE_CONFIG"], fallback].compactMap { $0 }.first { !$0.isEmpty && exists($0) }
    }
}
