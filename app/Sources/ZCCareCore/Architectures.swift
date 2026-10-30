import Foundation

/// The CPU kinds an executable carries code for, read from its Mach-O
/// header. An app without arm64 code runs only through Rosetta, which
/// Apple is phasing out.
public enum Architectures {
    public enum CPU: String, Sendable { case arm64, x86_64, other }

    /// Nil when the file is not Mach-O or cannot be read.
    public static func of(_ executable: URL) -> Set<CPU>? {
        // A bundle names its own executable: a FIFO or a link to a device
        // there would block the open or the read for good. O_NONBLOCK keeps
        // the open from waiting, and fstat on what was opened decides.
        let fd = open(executable.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        guard let head = try? handle.read(upToCount: 4096) else { return nil }
        return parse([UInt8](head))
    }

    /// The app's main executable needs Rosetta: x86_64 code and no arm64.
    public static func intelOnly(_ app: URL) -> Bool? {
        guard let executable = Bundle(url: app)?.executableURL, let cpus = of(executable) else { return nil }
        return !cpus.contains(.arm64) && cpus.contains(.x86_64)
    }

    static func parse(_ b: [UInt8]) -> Set<CPU>? {
        guard b.count >= 8 else { return nil }
        func big(_ at: Int) -> UInt32? {
            guard at + 4 <= b.count else { return nil }
            return b[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func little(_ at: Int) -> UInt32? { big(at).map { $0.byteSwapped } }
        switch big(0) {
        case 0xcafe_babe, 0xcafe_babf:
            // Universal: big-endian header, 20- or 32-byte entries.
            let stride = big(0) == 0xcafe_babf ? 32 : 20
            guard let count = big(4), count > 0, count < 32 else { return nil }
            var cpus: Set<CPU> = []
            for i in 0..<Int(count) {
                guard let type = big(8 + i * stride) else { break }
                cpus.insert(cpu(type))
            }
            return cpus.isEmpty ? nil : cpus
        case 0xcffa_edfe, 0xcefa_edfe:
            // Thin, little-endian on disk.
            return little(4).map { [cpu($0)] }
        default:
            return nil
        }
    }

    static func cpu(_ type: UInt32) -> CPU {
        switch type {
        case 0x0100_000c: .arm64
        case 0x0100_0007: .x86_64
        default: .other
        }
    }
}
