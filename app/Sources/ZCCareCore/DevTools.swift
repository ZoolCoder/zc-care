import Foundation

/// One line of `docker system df`: images, containers, volumes or build cache.
public struct DockerUsage: Sendable, Equatable, Identifiable {
    public var type: String
    public var total: Int
    public var active: Int
    public var size: Int64
    public var reclaimable: Int64

    public var id: String { type }
}

public enum Docker {
    static let timeout: TimeInterval = 15

    public static let pruneBuildCache = ["builder", "prune", "--force"]
    public static let pruneDanglingImages = ["image", "prune", "--force"]

    /// What Docker keeps, by kind. Nil when the daemon does not answer in
    /// time, such as Docker Desktop not running: then there is nothing to show.
    public static func usage(docker: String, env: [String: String], runner: (any Runner)? = nil) async -> [DockerUsage]? {
        let runner = runner ?? ProcessRunner(timeout: timeout)
        guard let r = try? await runner.run(docker, ["system", "df", "--format", "json"], env: env), r.status == 0 else { return nil }
        return parse(df: r.output)
    }

    /// One JSON object a line, sizes as "1.2GB" and reclaimable as "1.2GB (50%)".
    static func parse(df text: String) -> [DockerUsage] {
        struct Row: Decodable {
            var type: String, totalCount: String, active: String, size: String, reclaimable: String
            enum CodingKeys: String, CodingKey {
                case type = "Type", totalCount = "TotalCount", active = "Active", size = "Size", reclaimable = "Reclaimable"
            }
        }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)) else { return nil }
            return DockerUsage(type: row.type, total: Int(row.totalCount) ?? 0, active: Int(row.active) ?? 0,
                               size: bytes(row.size), reclaimable: bytes(row.reclaimable))
        }
    }

    /// "1.5GB" in Docker's decimal units; text after a space is ignored.
    static func bytes(_ text: String) -> Int64 {
        let size = text.split(separator: " ").first.map(String.init) ?? ""
        let number = size.prefix { $0.isNumber || $0 == "." }
        let unit = size.dropFirst(number.count).lowercased()
        let scale: Double = ["kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12][unit] ?? 1
        return Int64((Double(number) ?? 0) * scale)
    }
}

/// A folder Xcode keeps that it fills again, with the apps that must be closed
/// before it goes.
public struct XcodeSpot: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var url: URL
    public var size: Int64
    public var busyBundleIDs: [String]
}

public enum XcodeSpots {
    static let xcode = "com.apple.dt.Xcode", simulator = "com.apple.iphonesimulator"

    /// DerivedData, Archives, iOS DeviceSupport and the simulators' caches,
    /// those that exist and hold data, biggest first.
    public static func find(home: String) -> [XcodeSpot] {
        let junk = Junk.spots(home: home)
        func spot(_ id: String, busy: [String]) -> XcodeSpot? {
            guard let j = junk.first(where: { $0.id == id }) else { return nil }
            return XcodeSpot(id: id, title: j.title, detail: j.detail, url: URL(fileURLWithPath: j.path), size: 0, busyBundleIDs: busy)
        }
        let archives = XcodeSpot(id: "archives", title: "Xcode archives",
                                 detail: "Builds kept for App Store uploads and their symbols; Xcode cannot make them again.",
                                 url: URL(fileURLWithPath: home + "/Library/Developer/Xcode/Archives"), size: 0, busyBundleIDs: [xcode])
        let all = [spot("xcode", busy: [xcode]), archives, spot("devicesupport", busy: [xcode]),
                   spot("simulators", busy: [simulator, xcode])].compactMap { $0 }
        return all
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .map { spot in
                var spot = spot
                spot.size = DiskUsage.allocated(spot.url)
                return spot
            }
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
    }
}
