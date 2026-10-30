import CoreServices
import Foundation
import UniformTypeIdentifiers

/// What a large file is, by its type, for My Clutter's filter.
public enum FileKind: String, CaseIterable, Sendable {
    case videos = "Videos", music = "Music", pictures = "Pictures", archives = "Archives",
         installers = "Installers", documents = "Documents", other = "Other"

    public static func of(_ url: URL) -> FileKind {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if type.conforms(to: .movie) { return .videos }
        if type.conforms(to: .audio) { return .music }
        if type.conforms(to: .image) { return .pictures }
        if type.conforms(to: .diskImage) || type.identifier == "com.apple.installer-package-archive" { return .installers }
        if type.conforms(to: .archive) { return .archives }
        if [.pdf, .text, .presentation, .spreadsheet, .compositeContent, .epub].contains(where: type.conforms) { return .documents }
        return .other
    }

    /// When the file was last opened, from Spotlight; access dates are not
    /// used, since backups and indexing touch them too.
    public static func lastOpened(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Not opened for `days`: by its last open, or, never opened, by when
    /// it last changed.
    public static func unopened(_ file: LargeFile, days: Int = 365, now: Date = .now) -> Bool {
        guard let date = file.opened ?? file.modified else { return false }
        return date < now.addingTimeInterval(-Double(days) * 86400)
    }
}
