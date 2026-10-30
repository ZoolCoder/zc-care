import Foundation

/// Notices an app that left the Applications folders while its settings,
/// caches and data stay in the Library, so they can be cleared while it is
/// still clear whose they are. An app must be missing on two checks in a
/// row: an updater swaps its bundle out for a moment.
public struct LeftoverWatch: Sendable {
    /// Less than this is a preferences file or two, not worth a notification.
    public static let worth: Int64 = 1_000_000

    /// Bundle id to name, as the last check found them.
    private var known: [String: String]?
    private var missing: [String: String] = [:]

    public init() {}

    /// `installed` maps the bundle ids now in the Applications folders to
    /// their names. `elsewhere` says an id is still installed somewhere
    /// else, moved rather than removed. `size` is what an id and name left
    /// in the Library.
    public mutating func alerts(installed: [String: String], elsewhere: (String) -> Bool,
                                size: (String, String) -> Int64) -> [Alert] {
        defer { known = installed }
        guard let known else { return [] }
        let before = missing
        missing = known.filter { installed[$0.key] == nil }
        return before.filter { installed[$0.key] == nil }
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
            .compactMap { id, name in
                guard !elsewhere(id) else { return nil }
                let left = size(id, name)
                guard left >= Self.worth else { return nil }
                return Alert(id: "leftovers " + id,
                             title: "\(name) left \(ByteCountFormatter.string(fromByteCount: left, countStyle: .file)) behind",
                             body: "Its settings, caches and data are still in the Library. Click to review them.")
            }
    }

    /// The bundle ids of the apps in these folders, with their names; an id
    /// macOS would refuse is no app's.
    public static func installed(in folders: [URL]) -> [String: String] {
        var found: [String: String] = [:]
        for folder in folders {
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.pathExtension == "app" {
                guard let id = Bundle(url: url)?.bundleIdentifier, Leftovers.isBundleID(id) else { continue }
                found[id] = shown(url.deletingPathExtension().lastPathComponent)
            }
        }
        return found
    }

    /// A folder name fit for a notification: one short line.
    static func shown(_ name: String) -> String {
        let line = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        return line.count > 40 ? line.prefix(39) + "…" : line
    }
}
