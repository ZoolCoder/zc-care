import Foundation

/// A Simulator runtime Xcode downloaded: a disk image of an OS that
/// the simulators run, several gigabytes each.
public struct SimulatorRuntime: Sendable, Equatable, Identifiable {
    public var id: String
    public var platform: String
    public var version: String
    public var build: String
    public var size: Int64
    public var state: String
    /// False for a runtime Xcode bundles, which simctl refuses to delete.
    public var deletable = true

    public var title: String { "\(platform) \(version)" }
}

public enum Simulators {
    public static let xcrun = "/usr/bin/xcrun"
    public static let listRuntimes = ["simctl", "runtime", "list", "-j"]

    public static func deleteRuntime(_ id: String) -> [String] { ["simctl", "runtime", "delete", id] }

    /// The runtimes in `simctl runtime list -j`, an object keyed by identifier,
    /// by platform, the newest version first. Anything else gives none.
    public static func parse(runtimes json: Data) -> [SimulatorRuntime] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: [String: Any]] else { return [] }
        return root.compactMap { key, fields -> SimulatorRuntime? in
            guard let version = fields["version"] as? String else { return nil }
            let size = (fields["sizeBytes"] as? NSNumber) ?? (fields["diskUsage"] as? NSNumber)
            return SimulatorRuntime(id: fields["identifier"] as? String ?? key,
                                    platform: platformName(fields["platformIdentifier"] as? String ?? fields["runtimeIdentifier"] as? String),
                                    version: version, build: fields["build"] as? String ?? "",
                                    size: size?.int64Value ?? 0, state: fields["state"] as? String ?? "Unknown",
                                    deletable: fields["deletable"] as? Bool ?? true)
        }
        .sorted {
            $0.platform == $1.platform ? $0.version.compare($1.version, options: .numeric) == .orderedDescending
                : $0.platform < $1.platform
        }
    }

    /// The runtimes Xcode holds, or nil when xcrun does not answer.
    public static func runtimes(runner: any Runner, env: [String: String]) async -> [SimulatorRuntime]? {
        guard let r = try? await runner.run(xcrun, listRuntimes, env: env), r.status == 0 else { return nil }
        return parse(runtimes: r.stdout)
    }

    /// "com.apple.platform.iphonesimulator" or "...SimRuntime.iOS-18-5" as the OS is called.
    private static func platformName(_ identifier: String?) -> String {
        let names = ["iphone": "iOS", "ios": "iOS", "watch": "watchOS", "appletv": "tvOS", "tvos": "tvOS",
                     "xros": "visionOS", "xr": "visionOS", "vision": "visionOS"]
        let lowered = (identifier ?? "").lowercased()
        return names.first { lowered.contains($0.key) }?.value ?? "Simulator"
    }
}
