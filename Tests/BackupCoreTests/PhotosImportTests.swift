import Foundation
import Testing
@testable import BackupCore

/// Builds backup folders with simulated bytes and real manifests by running the folder engine.
final class ImportFixture {
    let root: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ppb-import-tests-\(UUID().uuidString)")
        destination = root.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Creates a source folder named `name` with `files` and backs it up into `destination`.
    @discardableResult
    func backup(_ name: String, _ files: [String: String]) throws -> URL {
        let source = root.appendingPathComponent("sources").appendingPathComponent(name)
        for (path, text) in files {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return try BackupEngine.run(BackupEngine.makePlan(source: source, destination: destination)).backupDirectory
    }

    func plan(_ ledger: ImportLedger = ImportLedger()) throws -> ImportPlan {
        try PhotosImport.makePlan(backupFolders: PhotosImport.backupFolders(in: destination), ledger: ledger)
    }
}

@Suite struct PhotosImportTests {
    @Test func identicalFilesAcrossBackupsAreImportedOnce() throws {
        let f = try ImportFixture()
        try f.backup("Old phone 1", ["DCIM/IMG_0001.HEIC": "beach", "DCIM/IMG_0002.JPG": "cat"])
        try f.backup("Old phone 2", ["DCIM/IMG_0105.HEIC": "beach", "DCIM/IMG_0002.JPG": "dog"])
        let plan = try f.plan()
        #expect(plan.items.count == 3) // beach once, cat, dog
        #expect(plan.duplicateFiles == 1)
    }

    @Test func livePhotosArePairedAndOtherFilesSkipped() throws {
        let f = try ImportFixture()
        try f.backup("Phone", [
            "DCIM/IMG_0001.HEIC": "still", "DCIM/IMG_0001.MOV": "motion", "DCIM/IMG_0001.AAE": "edits",
            "DCIM/IMG_0002.MOV": "plain video", "DCIM/notes.txt": "x",
        ])
        let plan = try f.plan()
        #expect(plan.items.count == 2)
        let live = try #require(plan.items.first { $0.isLivePhoto })
        #expect(live.photo?.filename == "IMG_0001.HEIC")
        #expect(live.video?.filename == "IMG_0001.MOV")
        #expect(plan.items.contains { $0.photo == nil && $0.video?.filename == "IMG_0002.MOV" })
        #expect(plan.otherFiles == 2)
    }

    @Test func ledgerPreventsImportingTwice() throws {
        let f = try ImportFixture()
        try f.backup("Phone", ["DCIM/IMG_0001.HEIC": "a", "DCIM/IMG_0002.HEIC": "b"])
        var ledger = ImportLedger()
        let first = try f.plan(ledger)
        ledger.record(first.items[0], assetID: "asset-1", existing: false)
        try ledger.write(to: f.destination)

        let reloaded = try ImportLedger.load(from: f.destination)
        let second = try f.plan(reloaded)
        #expect(second.items.count == 1)
        #expect(second.previouslyImportedFiles == 1)
        #expect(second.items[0].primary.filename != first.items[0].primary.filename)
    }

    @Test func missingBackupCopiesAreLeftOut() throws {
        let f = try ImportFixture()
        let folder = try f.backup("Phone", ["DCIM/IMG_0001.HEIC": "a", "DCIM/IMG_0002.HEIC": "b"])
        try FileManager.default.removeItem(at: folder.appendingPathComponent("DCIM/IMG_0001.HEIC"))
        #expect(try f.plan().items.map(\.primary.filename) == ["IMG_0002.HEIC"])
    }

    @Test func libraryIndexMatchesNameAndTimeWithTimeZoneShift() {
        var index = LibraryIndex()
        let taken = Date(timeIntervalSince1970: 1_700_000_000)
        index.add(filename: "IMG_1234.HEIC", date: taken)
        #expect(index.contains(filename: "IMG_1234.HEIC", date: taken))
        #expect(index.contains(filename: "img_1234.jpg", date: taken.addingTimeInterval(1)))
        #expect(index.contains(filename: "IMG_1234.HEIC", date: taken.addingTimeInterval(8 * 3600))) // no time zone in EXIF
        #expect(!index.contains(filename: "IMG_1234.HEIC", date: taken.addingTimeInterval(90))) // different photo
        #expect(!index.contains(filename: "IMG_1234.HEIC", date: taken.addingTimeInterval(400 * 86400))) // counter wrapped
        #expect(!index.contains(filename: "IMG_9999.HEIC", date: taken))
        #expect(!index.contains(filename: "IMG_1234.HEIC", date: nil))
    }
}
