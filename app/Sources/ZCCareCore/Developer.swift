import Foundation

/// Dependency folders a package manager fills inside a project: they come
/// back with the next install, so a project left alone does not need them.
public enum ProjectDependencies {
    /// Each kind and the file beside it that proves it is one: a folder
    /// called target is only Rust's or Maven's when a manifest sits next to it.
    static let kinds: [String: [String]] = [
        "node_modules": [],
        ".venv": ["pyvenv.cfg"],
        "venv": ["pyvenv.cfg"],
        "target": ["../Cargo.toml", "../pom.xml"],
    ]

    /// The folders where code usually lives, those that exist.
    public static func roots(home: String) -> [URL] {
        ["Developer", "Projects", "Code", "code", "src", "dev", "workspace", "git", "repos", "Documents/GitHub"]
            .map { URL(fileURLWithPath: home + "/" + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Dependency folders of projects not touched for `days`, biggest first;
    /// `modified` is when the project itself last changed.
    public static func find(roots: [URL], olderThan days: Int = 90, now: Date = .now, depth: Int = 6) -> [LargeFile] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        var found: [LargeFile] = []
        for root in roots {
            walk(root, depth: depth) { folder in
                let touched = lastTouched(project: folder.deletingLastPathComponent(), skipping: folder.lastPathComponent)
                guard touched < cutoff else { return }
                found.append(LargeFile(url: folder, size: DiskUsage.allocated(folder), modified: touched))
            }
        }
        return found.sorted { $0.size > $1.size }
    }

    /// The folders whose project changed within `days` since the list was
    /// read: work resumed there needs its dependencies.
    public static func touched(_ folders: [LargeFile], within days: Int = 90, now: Date = .now) -> [LargeFile] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return folders.filter {
            lastTouched(project: $0.url.deletingLastPathComponent(), skipping: $0.url.lastPathComponent) >= cutoff
        }
    }

    /// The folders whose project a running command points into: a dev
    /// server or a script there still loads its dependencies.
    public static func running(_ folders: [LargeFile], commands: [String]) -> [LargeFile] {
        folders.filter { AIClutter.used($0.url.deletingLastPathComponent(), by: commands) }
    }

    /// Calls `hit` for each dependency folder, and does not go into one.
    private static func walk(_ folder: URL, depth: Int, hit: (URL) -> Void) {
        guard depth > 0 else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        for child in children {
            if Task.isCancelled { return }
            let v = try? child.resourceValues(forKeys: Set(keys))
            guard v?.isDirectory == true, v?.isSymbolicLink != true, v?.isPackage != true else { continue }
            let name = child.lastPathComponent
            if let proofs = kinds[name] {
                if proofs.isEmpty || proofs.contains(where: { FileManager.default.fileExists(atPath: child.appendingPathComponent($0).path) }) {
                    hit(child)
                }
                continue
            }
            guard !name.hasPrefix(".") else { continue }
            walk(child, depth: depth - 1, hit: hit)
        }
    }

    /// How many entries lastTouched reads before it settles for what it has.
    static let touchedEntryCap = 2000

    /// The newest change among the project's own entries and those in its
    /// folders three levels down: editing src/app/main.ts changes none of
    /// the folders above it. A commit or a pull is work too, and moves
    /// .git/index or .git/HEAD. A project too big to read in full counts as
    /// touched now: its idleness cannot be shown.
    static func lastTouched(project: URL, skipping: String) -> Date {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        var newest = Date.distantPast
        var seen = 0
        var capped = false
        func visit(_ folder: URL, depth: Int) {
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
            for entry in entries where entry.lastPathComponent != ".DS_Store" {
                guard seen < touchedEntryCap, !Task.isCancelled else { capped = true; return }
                seen += 1
                let name = entry.lastPathComponent
                if folder == project, name == skipping { continue }
                let v = try? entry.resourceValues(forKeys: keys)
                newest = max(newest, v?.contentModificationDate ?? .distantPast)
                if v?.isDirectory == true, depth > 1, !name.hasPrefix("."), kinds[name] == nil {
                    visit(entry, depth: depth - 1)
                }
            }
        }
        visit(project, depth: 3)
        if capped { return .now }
        for name in ["index", "HEAD"] {
            let url = project.appendingPathComponent(".git/" + name)
            newest = max(newest, (try? url.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast)
        }
        return newest
    }
}

/// A local AI model on disk: what Ollama, LM Studio and Hugging Face keep.
public struct AIModel: Codable, Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable { case ollama = "Ollama", lmStudio = "LM Studio", huggingFace = "Hugging Face" }

    public var name: String
    public var source: Source
    public var size: Int64
    public var modified: Date?
    /// What removing it trashes: the model's folder, or an Ollama manifest
    /// and the blobs no other model shares.
    public var paths: [URL]

    public var id: String { source.rawValue + " " + name }
}

public enum AIModels {
    public static func find(home: String) -> [AIModel] {
        (ollama(root: URL(fileURLWithPath: home + "/.ollama/models"))
            + huggingFace(hub: URL(fileURLWithPath: home + "/.cache/huggingface/hub"))
            + lmStudio(folders: [home + "/.lmstudio/models", home + "/.cache/lm-studio/models"].map(URL.init(fileURLWithPath:))))
            .sorted { $0.size > $1.size }
    }

    /// What removing a model listed earlier may trash now: its reviewed
    /// paths it still owns alone. Nil when it is gone, or was pulled again
    /// and owns paths no one reviewed: removing part would strand the rest.
    public static func stillOwned(_ model: AIModel, in fresh: [AIModel]) -> [URL]? {
        guard let now = fresh.first(where: { $0.id == model.id }) else { return nil }
        let reviewed = Set(model.paths)
        guard now.paths.allSatisfy(reviewed.contains), !now.paths.isEmpty else { return nil }
        return now.paths
    }

    /// An `ollama pull` or `ollama create`: either may reuse a blob on disk.
    public static func isOllamaWriting(_ command: String) -> Bool {
        let words = command.split(separator: " ")
        guard let at = words.firstIndex(where: { $0 == "ollama" || $0.hasSuffix("/ollama") }), at + 1 < words.count else { return false }
        return ["pull", "create", "cp"].contains(words[at + 1])
    }

    private struct Manifest: Decodable {
        struct Layer: Decodable { var digest: String; var size: Int64 }
        var config: Layer?
        var layers: [Layer]
        var all: [Layer] { (config.map { [$0] } ?? []) + layers }
    }

    /// A manifest comes from a registry: only a plain sha256 digest may name a blob file.
    static func isBlobDigest(_ digest: String) -> Bool {
        digest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    /// manifests/<registry>/<namespace>/<model>/<tag>, each naming its
    /// blobs by digest; blobs/sha256-<hex> holds them. A blob two models
    /// share stays until the last one goes.
    static func ollama(root: URL) -> [AIModel] {
        guard let files = FileManager.default.enumerator(at: root.appendingPathComponent("manifests"), includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var read: [(url: URL, manifest: Manifest)] = []
        var users: [String: Int] = [:]
        let base = root.appendingPathComponent("manifests").resolvingSymlinksInPath().pathComponents.count
        for case let url as URL in files where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            // Only registry/namespace/model/tag files are manifests: a .DS_Store is not one.
            guard !url.lastPathComponent.hasPrefix("."), url.resolvingSymlinksInPath().pathComponents.count == base + 4 else { continue }
            // A manifest that does not decode may share any blob, so no blob is safe to remove.
            guard let data = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
            for d in Set(m.all.map(\.digest)) { users[d, default: 0] += 1 }
            if m.all.allSatisfy({ isBlobDigest($0.digest) }) { read.append((url, m)) }
        }
        return read.map { url, m in
            // The enumerator may answer with /private/var for /var: count from the end.
            let parts = url.pathComponents.suffix(3)
            let name = (parts.first == "library" ? "" : parts.first! + "/") + parts.dropFirst().joined(separator: ":")
            let own = Set(m.all.map(\.digest)).filter { users[$0] == 1 }
                .map { root.appendingPathComponent("blobs/" + $0.replacingOccurrences(of: ":", with: "-")) }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return AIModel(name: name, source: .ollama, size: m.all.reduce(0) { $0 + $1.size },
                           modified: modified, paths: [url] + own.sorted { $0.path < $1.path })
        }
    }

    /// hub/models--<org>--<name>, a folder per model.
    static func huggingFace(hub: URL) -> [AIModel] {
        folders(in: hub).compactMap { url in
            let folder = url.lastPathComponent
            guard folder.hasPrefix("models--") else { return nil }
            let name = folder.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            return model(name, .huggingFace, url)
        }
    }

    /// models/<publisher>/<model>, a folder per model.
    static func lmStudio(folders roots: [URL]) -> [AIModel] {
        roots.flatMap { root in
            folders(in: root).flatMap { publisher in
                folders(in: publisher).map { model(publisher.lastPathComponent + "/" + $0.lastPathComponent, .lmStudio, $0) }
            }
        }
    }

    private static func model(_ name: String, _ source: AIModel.Source, _ url: URL) -> AIModel {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return AIModel(name: name, source: source, size: DiskUsage.allocated(url), modified: modified, paths: [url])
    }

    private static func folders(in url: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                options: [.skipsHiddenFiles])) ?? []
        return all.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
}
