import Foundation
import Testing
@testable import BackupCore

/// All tests use temporary simulated bytes only — never real photos.
final class Fixture {
    let root: URL
    let source: URL
    let destination: URL
    let photo: URL
    static let originalBytes = Data("simulated photo bytes".utf8) + Data([0, 1])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ppb-tests-\(UUID().uuidString)")
        source = root.appendingPathComponent("Phone Export")
        destination = root.appendingPathComponent("External Backup")
        photo = source.appendingPathComponent("DCIM/photo.jpg")
        try FileManager.default.createDirectory(at: photo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Self.originalBytes.write(to: photo)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func plan() throws -> BackupPlan { try BackupEngine.makePlan(source: source, destination: destination) }
    func backup() throws -> BackupReport { try BackupEngine.run(try plan()) }
    func manifest(_ report: BackupReport) throws -> [String: Any] {
        let data = try Data(contentsOf: report.backupDirectory.appendingPathComponent(BackupEngine.manifestName))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite struct BackupEngineTests {
    @Test func copyIsVerifiedAndSourceIsPreserved() throws {
        let f = try Fixture()
        let report = try f.backup()
        let copied = report.backupDirectory.appendingPathComponent("DCIM/photo.jpg")
        #expect(report.copied == 1)
        #expect(report.errors.isEmpty)
        #expect(try Data(contentsOf: copied) == Fixture.originalBytes)
        #expect(try Data(contentsOf: f.photo) == Fixture.originalBytes)
        #expect(report.backupDirectory.lastPathComponent == "Phone Export_backup")
        let manifest = try f.manifest(report)
        #expect(manifest["schema_version"] as? Int == 1)
        #expect(manifest["source_name"] as? String == "Phone Export")
        let versions = try #require((manifest["files"] as? [String: Any])?["DCIM/photo.jpg"] as? [[String: Any]])
        #expect(versions.count == 1)
        #expect(versions[0]["backup_path"] as? String == "DCIM/photo.jpg")
        #expect(versions[0]["size_bytes"] as? Int == Fixture.originalBytes.count)
    }

    @Test func rerunSkipsUnchangedFiles() throws {
        let f = try Fixture()
        let first = try f.backup()
        let second = try f.backup()
        #expect(first.copied == 1)
        #expect(second.copied == 0)
        #expect(second.unchanged == 1)
    }

    @Test func changedFileIsSavedAsAConflictCopy() throws {
        let f = try Fixture()
        let first = try f.backup()
        try Data("new simulated photo bytes".utf8).write(to: f.photo)
        let second = try f.backup()
        let folder = first.backupDirectory.appendingPathComponent("DCIM")
        let conflicts = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("photo.conflict-") && $0.hasSuffix(".jpg") }
        #expect(try Data(contentsOf: folder.appendingPathComponent("photo.jpg")) == Fixture.originalBytes)
        #expect(conflicts.count == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent(conflicts[0])) == Data("new simulated photo bytes".utf8))
        let files = try #require(try f.manifest(second)["files"] as? [String: [Any]])
        #expect(files["DCIM/photo.jpg"]?.count == 2)
        #expect(second.copied == 1)

        // Running again with the changed file recognises the existing conflict copy.
        let third = try f.backup()
        #expect(third.copied == 0)
        #expect(third.unchanged == 1)
    }

    @Test func unreadableManifestStopsBeforeModifyingBackedUpFiles() throws {
        let f = try Fixture()
        let report = try f.backup()
        let backedUp = report.backupDirectory.appendingPathComponent("DCIM/photo.jpg")
        try Data("not json".utf8).write(to: report.backupDirectory.appendingPathComponent(BackupEngine.manifestName))
        try Data("changed source".utf8).write(to: f.photo)
        #expect(throws: BackupError(.manifestUnreadable)) { try f.backup() }
        #expect(try Data(contentsOf: backedUp) == Fixture.originalBytes)
    }

    @Test func overlappingSourceAndDestinationIsRejected() throws {
        let f = try Fixture()
        #expect(throws: BackupError(.overlap)) {
            try BackupEngine.makePlan(source: f.source, destination: f.source.appendingPathComponent("Backups"))
        }
    }

    @Test func symlinksAreNotFollowed() throws {
        let f = try Fixture()
        try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("linked.jpg"), withDestinationURL: f.photo)
        try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("linked-dir"),
                                                   withDestinationURL: f.photo.deletingLastPathComponent())
        let plan = try f.plan()
        #expect(plan.files.map(\.relativePath) == ["DCIM/photo.jpg"])
    }

    @Test func timestampsAndPermissionsArePreserved() throws {
        let f = try Fixture()
        let past = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: past, .posixPermissions: 0o640], ofItemAtPath: f.photo.path)
        let report = try f.backup()
        let attributes = try FileManager.default.attributesOfItem(atPath: report.backupDirectory.appendingPathComponent("DCIM/photo.jpg").path)
        #expect(attributes[.modificationDate] as? Date == past)
        #expect(attributes[.posixPermissions] as? Int == 0o640)
    }

    @Test func cancellationStopsAndStillWritesManifest() throws {
        let f = try Fixture()
        for index in 0..<5 {
            try Data("extra \(index)".utf8).write(to: f.source.appendingPathComponent("extra-\(index).bin"))
        }
        let plan = try f.plan()
        let counter = Counter()
        let report = try BackupEngine.run(plan, isCancelled: { counter.value >= 2 }, progress: { _, _, _, _ in counter.increment() })
        #expect(report.cancelled)
        #expect(report.copied == 2)
        #expect(FileManager.default.fileExists(atPath: report.backupDirectory.appendingPathComponent(BackupEngine.manifestName).path))
        let resumed = try BackupEngine.run(plan)
        #expect(resumed.unchanged == 2)
        #expect(resumed.copied == 4)
    }

    @Test func folderNamesAreSanitised() {
        #expect(BackupEngine.safeFolderName("a:b?c") == "a_b_c")
        #expect(BackupEngine.safeFolderName(" .. ") == "Phone Import")
        #expect(BackupEngine.safeFolderName("iPhone 照片.") == "iPhone 照片")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
