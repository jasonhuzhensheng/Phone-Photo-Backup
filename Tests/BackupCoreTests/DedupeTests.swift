import Foundation
import Testing
@testable import BackupCore

/// Files already stored by another backup on the same drive are not stored again.
@Suite struct DedupeTests {
    static let shared = Data("photo both phones have".utf8)

    /// Backs up phone A, then returns phone B's plan on the same destination.
    func twoPhones() async throws -> (DeviceFixture, FakeDevice, BackupPlan) {
        let a = try DeviceFixture([
            "DCIM/100APPLE/IMG_0001.HEIC": Self.shared,
            "DCIM/100APPLE/IMG_0002.MOV": Data("only on phone A".utf8),
        ])
        let first = try await a.backup()
        #expect(first.copied == 2)
        let b = FakeDevice([
            "DCIM/100APPLE/IMG_0001.HEIC": Self.shared,                 // same name, same bytes
            "DCIM/101APPLE/IMG_9000.HEIC": Self.shared,                 // renamed, same bytes
            "DCIM/100APPLE/IMG_0003.HEIC": Data("only on phone B".utf8),
        ])
        let plan = BackupEngine.makeDevicePlan(deviceName: "Phone B", deviceID: "device-B", files: b.files, destination: a.destination)
        return (a, b, plan)
    }

    @Test func previewCountsLikelyDuplicatesByNameAndSize() async throws {
        let (_, _, plan) = try await twoPhones()
        #expect(plan.existing.folders == ["Test iPhone_backup"])
        // Only the same-name file is a likely duplicate; the renamed one is confirmed during backup.
        #expect(plan.likelyDuplicates.count == 1)
        #expect(plan.likelyDuplicates.bytes == Int64(Self.shared.count))
    }

    @Test func duplicatesAreRecordedButNotStoredAgain() async throws {
        let (a, b, plan) = try await twoPhones()
        let report = try await BackupEngine.runStaged(plan, fetch: b.fetch)
        #expect(report.errors.isEmpty)
        #expect(report.copied == 1)
        #expect(report.duplicates == 2) // same name and renamed: both matched by SHA-256
        #expect(report.duplicateBytes == Int64(Self.shared.count) * 2)

        let folder = report.backupDirectory
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DCIM/100APPLE/IMG_0003.HEIC").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("DCIM/100APPLE/IMG_0001.HEIC").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("DCIM/101APPLE/IMG_9000.HEIC").path))

        // The manifest points at the copy in phone A's backup.
        let data = try Data(contentsOf: folder.appendingPathComponent(BackupEngine.manifestName))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try #require(json["files"] as? [String: [[String: Any]]])
        #expect(files["DCIM/101APPLE/IMG_9000.HEIC"]?.first?["backup_path"] as? String
                == "../Test iPhone_backup/DCIM/100APPLE/IMG_0001.HEIC")

        // Running again reads nothing new from phone B.
        let before = b.fetches("DCIM/101APPLE/IMG_9000.HEIC")
        let again = try await BackupEngine.runStaged(
            BackupEngine.makeDevicePlan(deviceName: "Phone B", deviceID: "device-B", files: b.files, destination: a.destination), fetch: b.fetch)
        #expect(again.unchanged == 3)
        #expect(b.fetches("DCIM/101APPLE/IMG_9000.HEIC") == before)
    }

    @Test func missingOtherCopyIsStoredInstead() async throws {
        let (a, b, plan) = try await twoPhones()
        // Phone A's copy disappeared after planning: store phone B's own copy.
        try FileManager.default.removeItem(at: a.destination.appendingPathComponent("Test iPhone_backup/DCIM/100APPLE/IMG_0001.HEIC"))
        let report = try await BackupEngine.runStaged(plan, fetch: b.fetch)
        #expect(report.duplicates == 0)
        // IMG_0001 and IMG_0003 are stored; IMG_9000 has IMG_0001's bytes and points at that copy.
        #expect(report.copied == 2)
        #expect(report.unchanged == 1)
    }

    @Test func folderBackupsSkipFilesStoredByAnotherBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppb-dedupe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Drive")
        for (folder, files) in [("Export A", ["a.jpg": Self.shared]),
                                ("Export B", ["sub/b.jpg": Self.shared, "new.jpg": Data("new".utf8)])] {
            for (path, bytes) in files {
                let url = root.appendingPathComponent(folder).appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url)
            }
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try BackupEngine.run(BackupEngine.makePlan(source: root.appendingPathComponent("Export A"), destination: destination))
        let report = try BackupEngine.run(BackupEngine.makePlan(source: root.appendingPathComponent("Export B"), destination: destination))
        #expect(report.copied == 1)
        #expect(report.duplicates == 1)
        #expect(report.bytesCopied == 3)
    }

    @Test func fileMovedToAnotherFolderOnThePhoneIsNotStoredTwice() async throws {
        // Large iPhone libraries regroup files into differently named folders between sessions.
        let f = try DeviceFixture(["DCIM/201604__/IMG_1951.JPG": Self.shared])
        let first = try await f.backup()
        #expect(first.copied == 1)
        let moved = FakeDevice(["DCIM/201604_a/IMG_1951.JPG": Self.shared])
        let report = try await BackupEngine.runStaged(
            BackupEngine.makeDevicePlan(deviceName: "Test iPhone", deviceID: f.deviceID, files: moved.files, destination: f.destination),
            fetch: moved.fetch)
        #expect(report.copied == 0)
        #expect(report.unchanged == 1)
        let folder = report.backupDirectory.appendingPathComponent("DCIM")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["201604__"])
    }

    @Test func plainReferenceFolderIsComparedByNameSizeAndSHA() async throws {
        let f = try DeviceFixture([
            "DCIM/100APPLE/IMG_0001.HEIC": Self.shared,                // same name + bytes as the reference
            "DCIM/100APPLE/IMG_0002.HEIC": Data("same size, other bytes!".utf8.prefix(Self.shared.count)),
            "DCIM/100APPLE/IMG_0003.HEIC": Data("new".utf8),
        ])
        // An old export somewhere else, not made by this app, with a renamed copy.
        let reference = f.root.appendingPathComponent("Old phone export/2024")
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        try Self.shared.write(to: reference.appendingPathComponent("IMG_0001.HEIC"))
        try Self.shared.write(to: reference.appendingPathComponent("copy of photo.heic"))
        let plan = BackupEngine.makeDevicePlan(deviceName: "Phone C", deviceID: "device-C", files: f.device.files, destination: f.destination,
                                               references: [f.root.appendingPathComponent("Old phone export")])
        #expect(plan.existing.folders == ["Old phone export"])
        #expect(plan.likelyDuplicates.count == 1)

        let report = try await BackupEngine.runStaged(plan, fetch: f.device.fetch)
        #expect(report.errors.isEmpty)
        #expect(report.duplicates == 1)  // IMG_0001 (exact bytes found in the reference)
        #expect(report.copied == 2)      // IMG_0002 has the same size but different bytes; IMG_0003 is new
        let data = try Data(contentsOf: report.backupDirectory.appendingPathComponent(BackupEngine.manifestName))
        let files = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["files"] as? [String: [[String: Any]]])
        // Either identical copy in the reference is fine.
        #expect((files["DCIM/100APPLE/IMG_0001.HEIC"]?.first?["backup_path"] as? String)?.contains("Old phone export/2024/") == true)
    }

    @Test func referenceToABackupOnAnotherDriveUsesItsManifest() async throws {
        let (a, b, _) = try await twoPhones()
        // Phone A's backup now counts as "another drive": back up phone B to a new destination.
        let newDrive = a.root.appendingPathComponent("New drive")
        try FileManager.default.createDirectory(at: newDrive, withIntermediateDirectories: true)
        let plan = BackupEngine.makeDevicePlan(deviceName: "Phone B", deviceID: "device-B", files: b.files, destination: newDrive,
                                               references: [a.destination.appendingPathComponent("Test iPhone_backup")])
        #expect(plan.existing.folders == ["Test iPhone_backup"])
        let report = try await BackupEngine.runStaged(plan, fetch: b.fetch)
        #expect(report.duplicates == 2)
        #expect(report.copied == 1)
    }

    @Test func referenceInsideTheSourceFolderIsIgnored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppb-ref-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Export")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Self.shared.write(to: source.appendingPathComponent("sub/a.jpg"))
        let destination = root.appendingPathComponent("Drive")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let plan = try BackupEngine.makePlan(source: source, destination: destination,
                                             references: [source.appendingPathComponent("sub"), root])
        #expect(plan.existing.isEmpty)
        #expect(try BackupEngine.run(plan).copied == 1)
    }

    @Test func relativePathsBetweenBackups() {
        #expect(BackupEngine.relativePath(of: "/V/b_backup/x/y.jpg", from: "/V/b_backup") == "x/y.jpg")
        #expect(BackupEngine.relativePath(of: "/V/a_backup/x/y.jpg", from: "/V/b_backup") == "../a_backup/x/y.jpg")
    }
}
