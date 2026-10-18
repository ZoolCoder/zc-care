import Foundation

/// How an app goes when ZC Care uninstalls it.
public enum Uninstall: Sendable, Equatable {
    /// zc-care remove: uninstalls it and drops it from the manifest.
    case remove(target: String, resource: String)
    /// brew uninstall --cask, for a cask nothing declares.
    case cask(String)
    /// The Trash, where it can be put back.
    case trash

    public static func method(declared: Item?, source: InstalledApp.Source) -> Uninstall {
        if let item = declared, let target = item.target { return .remove(target: target, resource: item.resource) }
        if case .cask(let token) = source { return .cask(token) }
        return .trash
    }
}

extension Launchd {
    /// The launchctl calls that turn an agent off for good, or back on: the
    /// override outlives the plist, and the agent stops or starts now too.
    public static func toggleSteps(domain: String, label: String, plist: String, on: Bool) -> [[String]] {
        let target = domain + "/" + label
        return on ? [["enable", target], ["bootstrap", domain, plist]] : [["bootout", target], ["disable", target]]
    }

    /// Whether a step's failure is one: bootout fails when the agent is not
    /// loaded, bootstrap when it is.
    public static func mustSucceed(_ step: [String]) -> Bool {
        step.first == "enable" || step.first == "disable"
    }
}

/// When Smart Care looks again by itself, and what it says when it does.
public enum CareSchedule {
    public static let interval: TimeInterval = 7 * 86400
    /// Junk worth a notification.
    public static let threshold: Int64 = 2_000_000_000

    public static func due(last: Date?, now: Date = .now) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Alert ids start with "care", so a click opens the Care window.
    public static func alerts(junk: Int64, outdated: Int, findings: Int) -> [Alert] {
        var alerts: [Alert] = []
        if junk >= threshold {
            alerts.append(Alert(id: "care junk", title: "\(bytes(junk)) of junk to clear",
                                body: "Smart Care found caches, logs and build output to clean up."))
        }
        if outdated > 0 {
            alerts.append(Alert(id: "care updates", title: outdated == 1 ? "1 update waiting" : "\(outdated) updates waiting",
                                body: "Open Smart Care to update."))
        }
        if findings > 0 {
            alerts.append(Alert(id: "care health", title: findings == 1 ? "1 health finding" : "\(findings) health findings",
                                body: "The weekly scan found something to look at."))
        }
        return alerts
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

/// Homebrew's cask index, to find the cask that installs an app put in
/// /Applications by hand.
public enum CaskIndex {
    /// Homebrew's API cache: a JWS whose payload is the JSON of every
    /// formula and cask. Each app bundle's name maps to its cask.
    public static func apps(jws: Data) -> [String: String] {
        guard let outer = try? JSONSerialization.jsonObject(with: jws) as? [String: Any],
              let payload = (outer["payload"] as? String)?.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let casks = root["casks"] as? [String: [String: Any]] else { return [:] }
        var apps: [String: String] = [:]
        for (token, cask) in casks.sorted(by: { $0.key < $1.key }) {
            for artifact in cask["raw_artifacts"] as? [[Any]] ?? [] {
                guard artifact.first as? String == ":app", let names = artifact.dropFirst().first as? [Any] else { continue }
                for case let name as String in names where apps[name] == nil {
                    apps[name] = token
                }
            }
        }
        return apps
    }

    /// The target that declares the most casks: where an adopted one goes.
    public static func target(items: [Item]) -> String? {
        let counts = Dictionary(items.filter { $0.kind == "cask" }.compactMap(\.target).map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }
}
