import Foundation

/// What one run did, item by item: the completion sheet shows it, and
/// its text is the log the user can copy.
public struct RunLog: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        public var name: String
        /// Where the item was, or what it was.
        public var detail: String
        public var size: Int64
        /// Why the item stayed; nil once it went.
        public var failure: String?

        public init(name: String, detail: String, size: Int64, failure: String? = nil) {
            self.name = name
            self.detail = detail
            self.size = size
            self.failure = failure
        }

        public var id: String { path }
        public var done: Bool { failure == nil }
        public var path: String { detail.isEmpty ? name : detail + "/" + name }
    }

    public var title: String
    /// Deleted for good, or moved to the Trash: the wording follows.
    public var permanent: Bool
    public var started: Date
    public var finished: Date?
    public var lines: [Line] = []

    public init(title: String, permanent: Bool, started: Date = .now) {
        self.title = title
        self.permanent = permanent
        self.started = started
    }

    public mutating func add(_ line: Line) { lines.append(line) }

    public mutating func end(at date: Date = .now) { finished = date }

    /// Logs one item by what its removal reported: a failure under its
    /// name means it stayed.
    public mutating func add(_ url: URL, size: Int64, removal: Removal) {
        let failure = removal.failures.first { $0.name == url.lastPathComponent }?.reason.label
        add(Line(name: url.lastPathComponent, detail: url.deletingLastPathComponent().path, size: size, failure: failure))
    }

    /// Logs a batch that went to the Trash in one go: what the Trash
    /// reports as moved went, the rest stayed with the one error.
    public mutating func add(_ urls: [(url: URL, size: Int64)], trashed: [Trashed], failure: String?) {
        let moved = Set(trashed.map(\.original))
        for item in urls {
            let went = failure == nil || moved.contains(item.url.path)
            add(Line(name: item.url.lastPathComponent, detail: item.url.deletingLastPathComponent().path, size: item.size,
                     failure: went ? nil : failure))
        }
    }

    public var done: [Line] { lines.filter(\.done) }
    public var failed: [Line] { lines.filter { !$0.done } }
    public var freed: Int64 { done.reduce(0) { $0 + $1.size } }
    public var allDone: Bool { failed.isEmpty }

    /// One line for the sheet's heading: what went, and what stayed.
    public var summary: String {
        let verb = permanent ? "deleted" : "moved to the Trash"
        let count = done.count == lines.count ? "\(lines.count) \(lines.count == 1 ? "item" : "items")"
                                              : "\(done.count) of \(lines.count) items"
        var text = "\(count) \(verb), \(bytes(freed)) freed"
        if !failed.isEmpty { text += "; \(failed.count) stayed" }
        return text + "."
    }

    /// The log as text, one item a line, for the clipboard.
    public var text: String {
        let stamp = ISO8601DateFormatter().string(from: finished ?? started)
        var out = ["\(title) · \(stamp)", summary, ""]
        for line in lines {
            out.append(line.done ? "ok    \(line.path) (\(bytes(line.size)))" : "stayed \(line.path): \(line.failure ?? "")")
        }
        return out.joined(separator: "\n")
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
