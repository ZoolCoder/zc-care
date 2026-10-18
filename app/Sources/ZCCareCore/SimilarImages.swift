import Foundation
import ImageIO
import Vision

/// Photos that look alike: bursts, edits and resaved copies. The first is
/// the one to keep, the one with the most pixels.
public struct SimilarGroup: Sendable, Equatable, Identifiable {
    public var files: [LargeFile]

    public var id: String { files.map(\.id).joined(separator: "\n") }
    public var best: LargeFile { files[0] }
    public var others: [LargeFile] { Array(files.dropFirst()) }
    public var wasted: Int64 { others.reduce(0) { $0 + $1.size } }
}

public enum SimilarImages {
    /// Spotlight's query for images worth comparing, in the folders photos
    /// land in.
    public static let query = "kMDItemContentTypeTree == 'public.image' && kMDItemFSSize >= 100000"
    public static func folders(home: String) -> [String] {
        ["Pictures", "Desktop", "Downloads", "Documents"].map { home + "/" + $0 }
    }

    /// Feature prints closer than this look alike to a person. A resized or
    /// resaved copy measures under 0.1; the same picture in another colour
    /// near 0.27, which stays apart.
    static let threshold: Float = 0.25
    /// Comparing is pairwise, so the newest this many images only.
    public static let limit = 1500

    /// Groups the images Spotlight found, biggest waste first. Photos and
    /// other app libraries are left out: their files belong to the app,
    /// as those in a git repo belong to the project.
    public static func groups(paths: [String], home: String, minimum: Int64 = 100_000) -> [SimilarGroup] {
        let files = Duplicates.outsideRepos(LargeFiles.candidates(paths: paths, home: home, minimum: minimum), home: home)
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            .prefix(limit)
        let printed = files.compactMap { file in featurePrint(file.url).map { (file, $0) } }
        let clusters = cluster(count: printed.count) { i, j in
            var d: Float = .infinity
            try? printed[i].1.computeDistance(&d, to: printed[j].1)
            return d
        }
        return clusters.map { indices in
            let group = indices.map { printed[$0].0 }
            return SimilarGroup(files: ranked(group, pixels: pixels))
        }
        .sorted { $0.wasted > $1.wasted }
    }

    /// Indices that chain together under the threshold, in groups of two or
    /// more, each in the order given.
    static func cluster(count: Int, distance: (Int, Int) -> Float) -> [[Int]] {
        var parent = Array(0..<count)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in 0..<count {
            for j in (i + 1)..<max(count, i + 1) where distance(i, j) < threshold {
                parent[root(j)] = root(i)
            }
        }
        return Dictionary(grouping: 0..<count, by: root).values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// Most pixels first, then the bigger file, then the newer.
    static func ranked(_ files: [LargeFile], pixels: (URL) -> Int) -> [LargeFile] {
        files.map { ($0, pixels($0.url)) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.size != b.0.size { return a.0.size > b.0.size }
                return (a.0.modified ?? .distantPast) > (b.0.modified ?? .distantPast)
            }
            .map(\.0)
    }

    static func pixels(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        return (p[kCGImagePropertyPixelWidth] as? Int ?? 0) * (p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    static func featurePrint(_ url: URL) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(url: url).perform([request])
        return request.results?.first
    }
}
