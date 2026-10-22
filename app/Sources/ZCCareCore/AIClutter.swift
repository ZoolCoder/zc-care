import Foundation

/// What an AI tool leaves behind that it can do without: temp files, old
/// versions of itself, caches and logs. Chats, settings and sessions stay.
public struct AIJunk: Sendable, Equatable, Identifiable {
    public var tool: String
    public var kind: String
    public var paths: [URL]
    public var size: Int64

    public var id: String { tool + " " + kind }
}

public enum AIClutter {
    /// The picked paths a fresh scan still finds: a temp folder a session
    /// started using since the first scan is no longer junk.
    public static func stillJunk(_ picked: [AIJunk], in fresh: [AIJunk]) -> [URL] {
        let now = Set(fresh.flatMap(\.paths).map(\.standardizedFileURL.path))
        return picked.flatMap(\.paths).filter { now.contains($0.standardizedFileURL.path) }
    }

    /// Where a tool keeps one kind of junk: the folder itself, or only those
    /// of its entries that `pick` lets through.
    struct Spot {
        var tool: String
        var kind: String
        var path: String
        var pick: ((URL) -> Bool)? = nil
    }

    /// Each tool's junk by kind, biggest first; empty spots are left out.
    /// `claudeTemp` is Claude Code's folder in /tmp, /private/tmp/claude-<uid>.
    /// Caches of the `open` apps stay, and so does what running `commands`
    /// use, such as the Chrome profile Chrome DevTools MCP runs from.
    public static func find(home: String, claudeTemp: String, now: Date = .now,
                            open: Set<String> = [], commands: [String] = []) -> [AIJunk] {
        merged(spots(home: home, claudeTemp: claudeTemp, now: now).compactMap { spot -> AIJunk? in
            guard spot.kind != "Caches" || !open.contains(spot.tool) else { return nil }
            let paths = items(spot).filter { !used($0, by: commands) }
            let size = paths.reduce(0) { $0 + DiskUsage.allocated($1) }
            return size > 0 ? AIJunk(tool: spot.tool, kind: spot.kind, paths: paths, size: size) : nil
        })
    }

    static func spots(home: String, claudeTemp: String, now: Date) -> [Spot] {
        let support = home + "/Library/Application Support/"
        var spots = [
            // A session's temp folder is busy while it runs: a day untouched means it is done.
            Spot(tool: "Claude Code", kind: "Temp Files", path: claudeTemp, pick: { untouched($0, for: 1, now: now, deep: true) }),
            Spot(tool: "Claude Code", kind: "Logs", path: home + "/.claude/debug", pick: { _ in true }),
            Spot(tool: "Claude", kind: "Caches", path: home + "/Library/Caches/com.anthropic.claudefordesktop"),
            Spot(tool: "Claude", kind: "Caches", path: home + "/Library/Caches/com.anthropic.claudefordesktop.ShipIt"),
            Spot(tool: "Claude", kind: "Logs", path: home + "/Library/Logs/Claude", pick: { _ in true }),
            Spot(tool: "ChatGPT", kind: "Caches", path: home + "/Library/Caches/com.openai.chat"),
            Spot(tool: "Codex", kind: "Logs", path: home + "/.codex/log", pick: { _ in true }),
            Spot(tool: "Gemini CLI", kind: "Temp Files", path: home + "/.gemini/tmp", pick: { _ in true }),
            Spot(tool: "Chrome DevTools MCP", kind: "Caches", path: home + "/.cache/chrome-devtools-mcp"),
        ]
        if let current = claudeVersion(home: home) {
            spots.append(Spot(tool: "Claude Code", kind: "Stale Versions", path: home + "/.local/share/claude/versions",
                              pick: { $0.lastPathComponent != current }))
        }
        // Electron apps keep the same caches under their own name.
        for (tool, folder) in [("Claude", "Claude"), ("Cursor", "Cursor"), ("Windsurf", "Windsurf"), ("ChatGPT", "ChatGPT")] {
            for cache in ["Cache", "Code Cache", "GPUCache", "CachedData"] {
                spots.append(Spot(tool: tool, kind: "Caches", path: support + folder + "/" + cache))
            }
            spots.append(Spot(tool: tool, kind: "Logs", path: support + folder + "/logs", pick: { _ in true }))
        }
        return spots
    }

    /// The version ~/.local/bin/claude runs; nil when it is not a link into
    /// versions, and then none is called stale.
    static func claudeVersion(home: String) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: home + "/.local/bin/claude"),
              target.contains("/claude/versions/") else { return nil }
        return (target as NSString).lastPathComponent
    }

    /// What a spot names on disk: the folder, or the entries it picks.
    private static func items(_ spot: Spot) -> [URL] {
        let url = URL(fileURLWithPath: spot.path)
        guard OwnFolder.check(spot.path) else { return [] }
        guard let pick = spot.pick else { return [url] }
        let all = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return all.filter(pick)
    }

    /// A command names the path or something inside it.
    public static func used(_ url: URL, by commands: [String]) -> Bool {
        let path = url.path
        return commands.contains { command in
            var rest = command[...]
            while let found = rest.range(of: path) {
                let next = rest[found.upperBound...].first
                if next.map({ !isPathCharacter($0) }) ?? true { return true }
                rest = rest[found.upperBound...]
            }
            return false
        }
    }

    /// A longer name such as /tmp/claude-5011 is another path; anything else after the path ends it.
    private static func isPathCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "._-+@~%,".contains(c)
    }

    /// With `deep`, the newest change anywhere inside counts: a session that
    /// keeps writing deep in its folder leaves the folder's own date alone.
    static func untouched(_ url: URL, for days: Double, now: Date, deep: Bool = false) -> Bool {
        let key = URLResourceKey.contentModificationDateKey
        var newest = (try? url.resourceValues(forKeys: [key]))?.contentModificationDate ?? .distantPast
        if deep, let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [key]) {
            for case let inner as URL in walk {
                if let date = (try? inner.resourceValues(forKeys: [key]))?.contentModificationDate { newest = max(newest, date) }
            }
        }
        return now.timeIntervalSince(newest) > days * 86400
    }

    /// One entry per tool and kind: Claude's caches sit in several folders.
    static func merged(_ junk: [AIJunk]) -> [AIJunk] {
        var out: [AIJunk] = []
        for j in junk {
            if let i = out.firstIndex(where: { $0.id == j.id }) {
                out[i].paths += j.paths
                out[i].size += j.size
            } else {
                out.append(j)
            }
        }
        return out.sorted { $0.size > $1.size }
    }
}
