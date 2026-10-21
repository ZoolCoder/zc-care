import Foundation
import Testing
@testable import ZCCareCore

private func scratch(_ names: [String]) throws -> (folder: URL, files: [URL]) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-trash-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let files = try names.map { name -> URL in
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }
    return (folder, files)
}

@Test func removeGoesToTheTrashAndPutsBack() throws {
    let (folder, files) = try scratch(["a.bin", "b.bin"])
    defer {
        try? FileManager.default.removeItem(at: folder)
    }
    let removal = Removal.remove(files, permanently: false)
    defer { removal.trashed.forEach { try? FileManager.default.removeItem(atPath: $0.inTrash) } }
    #expect(removal.stayed == 0)
    #expect(removal.trashed.count == 2)
    #expect(removal.trashed.map(\.original).sorted() == files.map(\.path).sorted())
    #expect(removal.trashed.allSatisfy { FileManager.default.fileExists(atPath: $0.inTrash) })
    #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

    #expect(Trashed.putBack(removal.trashed).isEmpty)
    #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
}

@Test func removePermanentlyLeavesNothingToPutBack() throws {
    let (folder, files) = try scratch(["a.bin"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let removal = Removal.remove(files, permanently: true)
    #expect(removal.stayed == 0)
    #expect(removal.trashed.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: files[0].path))
}

@Test func removingWhatIsGoneAlreadyIsNotAFailure() throws {
    let (folder, files) = try scratch(["a.bin"])
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.removeItem(at: files[0])
    #expect(Removal.remove(files, permanently: false).stayed == 0)
}

@Test func junkEmptiesToTheTrashByDefault() throws {
    let (folder, files) = try scratch(["a.bin", "b.bin"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let spot = Junk(id: "t", title: "t", detail: "", path: folder.path)
    let removal = spot.empty(only: ["a.bin"])
    defer { removal.trashed.forEach { try? FileManager.default.removeItem(atPath: $0.inTrash) } }
    #expect(removal.trashed.map { URL(fileURLWithPath: $0.original).lastPathComponent } == ["a.bin"])
    #expect(FileManager.default.fileExists(atPath: files[1].path))
}
