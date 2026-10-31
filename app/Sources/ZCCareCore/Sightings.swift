import Foundation

/// When each launch agent and background item was first seen, kept on disk,
/// so the ones that appeared in the last week can be marked New.
public struct Sightings: Codable, Sendable, Equatable {
    /// List kind, then item id, then the day it was first seen. Items there
    /// on the first read of a list are stamped distantPast: they are not new.
    var seen: [String: [String: Date]] = [:]

    public init() {}

    public static let window: TimeInterval = 7 * 86400

    /// Notes what a list holds now. Items not seen before get `now`; items
    /// that left are forgotten, so one that returns counts as new.
    public mutating func record(_ kind: String, ids: [String], at now: Date = .now) {
        let before = seen[kind]
        let firstRead = before == nil
        var after: [String: Date] = [:]
        for id in ids { after[id] = before?[id] ?? (firstRead ? .distantPast : now) }
        seen[kind] = after
    }

    /// Whether the item first showed up within the last week.
    public func isNew(_ kind: String, _ id: String, at now: Date = .now) -> Bool {
        seen[kind]?[id].map { now.timeIntervalSince($0) < Self.window } ?? false
    }

    public static func load(from url: URL) -> Sightings {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Sightings.self, from: $0) } ?? Sightings()
    }

    public func save(to url: URL) throws {
        try PrivateFile.write(JSONEncoder().encode(self), to: url)
    }
}
