import Foundation

/// The owner's pick of the packages a config declares: which to install on
/// this Mac and which to skip, grouped under the manifest's sections. What
/// is left unpicked goes on the skip list, so plan and drift stop asking.
public struct AppChoice: Sendable, Equatable {
    public struct Section: Sendable, Equatable, Identifiable {
        public var name: String
        public var items: [Item]
        public var id: String { name }
    }

    /// Kinds a person picks; taps follow the packages that need them.
    static let kinds: Set<String> = ["brew", "cask", "mas"]

    public private(set) var items: [Item]
    /// The picked items' resources, such as cask:ghostty.
    public var picked: Set<String>

    /// Starts with everything picked except what this Mac already skips.
    public init(items: [Item]) {
        self.items = items.filter { Self.kinds.contains($0.kind) && $0.state != "not declared" && $0.state != "manual" }
        picked = Set(self.items.filter { $0.state != "skipped" }.map(\.resource))
    }

    /// The manifest's sections, in file order; entries above the first
    /// heading go under Other.
    public var sections: [Section] {
        var out: [Section] = []
        for item in items {
            let name = item.section ?? "Other"
            if let n = out.firstIndex(where: { $0.name == name }) {
                out[n].items.append(item)
            } else {
                out.append(Section(name: name, items: [item]))
            }
        }
        return out
    }

    public static func isInstalled(_ item: Item) -> Bool { item.state == "in place" || item.state == "outdated" }

    /// What a pick can still change: an installed package stays installed.
    public var choosable: [Item] { items.filter { !Self.isInstalled($0) } }

    public func isPicked(_ item: Item) -> Bool { picked.contains(item.resource) }

    public mutating func toggle(_ item: Item) {
        if picked.remove(item.resource) == nil { picked.insert(item.resource) }
    }

    /// The profiles the manifest's headings name, in file order, such as
    /// developer and everyday.
    public var profiles: [String] {
        var out: [String] = []
        for p in items.flatMap({ $0.profiles ?? [] }) where !out.contains(p) { out.append(p) }
        return out
    }

    /// Picks what a profile gets: the sections tagged for it and the ones
    /// tagged for no one in particular. Nil picks everything.
    public mutating func choose(profile: String?) {
        choose(profiles: profile.map { [$0] })
    }

    /// Picks what a Mac for these profiles gets: the sections tagged for
    /// one of them and the untagged ones. Nil or none picks everything.
    public mutating func choose(profiles: Set<String>?) {
        let profiles = profiles ?? []
        for item in choosable {
            let tags = item.profiles ?? []
            if !profiles.isEmpty, !tags.isEmpty, profiles.isDisjoint(with: tags) {
                picked.remove(item.resource)
            } else {
                picked.insert(item.resource)
            }
        }
    }

    /// Picks or unpicks every choosable item of a section.
    public mutating func set(_ section: Section, picked on: Bool) {
        for item in section.items where !Self.isInstalled(item) {
            if on { picked.insert(item.resource) } else { picked.remove(item.resource) }
        }
    }

    /// Missing packages the owner left out: they go on the skip list.
    public var toSkip: [String] {
        choosable.filter { $0.state != "skipped" && !isPicked($0) }.map(\.resource)
    }

    /// Skipped packages the owner picked again: they come off the list.
    public var toUnskip: [String] {
        choosable.filter { $0.state == "skipped" && isPicked($0) }.map(\.resource)
    }

    /// The packages an apply will install.
    public var toInstall: [Item] { choosable.filter(isPicked) }
}
