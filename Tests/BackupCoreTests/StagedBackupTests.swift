import Foundation
import Testing
@testable import BackupCore

/// A pretend phone: relative path → simulated bytes. Counts how often each file is fetched.
final class FakeDevice: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String: Data]
    private var fetchCounts: [String: Int] = [:]
    var truncate: Set<String> = []
    var failing: Set<String> = []

    init(_ contents: [String: Data]) { self.contents = contents }

    func set(_ path: String, _ data: Data) { lock.withLock { contents[path] = data } }
    func fetches(_ path: String) -> Int { lock.withLock { fetchCounts[path, default: 0] } }

    var files: [PlannedFile] {
        lock.withLock { contents.map { PlannedFile(relativePath: $0.key, size: Int64($0.value.count)) } }
    }

    var fetch: BackupEngine.Fetch {
        { [self] file, directory in
            let (data, cut, fail) = lock.withLock { () -> (Data?, Bool, Bool) in
                fetchCounts[file.relativePath, default: 0] += 1
                return (contents[file.relativePath], truncate.contains(file.relativePath), failing.contains(file.relativePath))
            }
            if fail { throw CocoaError(.fileReadUnknown) }
            let bytes = try #require(data)
            let url = directory.appendingPathComponent(UUID().uuidString + "-" + (file.relativePath as NSString).lastPathComponent)
            try (cut ? bytes.prefix(bytes.count / 2) : bytes).write(to: url)
            return url
        }
    }
}

final class DeviceFixture {
    let root: URL
    let destination: URL
    let device: FakeDevice

    init(_ contents: [String: Data] = [
        "DCIM/100APPLE/IMG_0001.HEIC": Data("simulated heic".utf8),
        "DCIM/100APPLE/IMG_0002.MOV": Data("simulated movie bytes".utf8) + Data([0, 255]),
    ]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ppb-device-tests-\(UUID().uuidString)")
        destination = root.appendingPathComponent("External Backup")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        device = FakeDevice(contents)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func plan() -> BackupPlan {
        BackupEngine.makeDevicePlan(deviceName: "Test iPhone", files: device.files, destination: destination)
    }

    func backup(isCancelled: @escaping @Sendable () -> Bool = { false }, progress: BackupProgress? = nil) async throws -> BackupReport {
        try await BackupEngine.runStaged(plan(), fetch: device.fetch, isCancelled: isCancelled, progress: progress)
    }
}

@Suite struct StagedBackupTests {
    @Test func deviceFilesAreCopiedAndRecorded() async throws {
        let f = try DeviceFixture()
        let report = try await f.backup()
        #expect(report.copied == 2)
        #expect(report.errors.isEmpty)
        #expect(report.backupDirectory.lastPathComponent == "Test iPhone_backup")
        let copied = report.backupDirectory.appendingPathComponent("DCIM/100APPLE/IMG_0001.HEIC")
        #expect(try Data(contentsOf: copied) == Data("simulated heic".utf8))
        // The staging folder is removed afterwards.
        #expect(!FileManager.default.fileExists(atPath: report.backupDirectory.appendingPathComponent(BackupEngine.stagingFolderName).path))
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf:
            report.backupDirectory.appendingPathComponent(BackupEngine.manifestName))) as? [String: Any])
        #expect(manifest["source_name"] as? String == "Test iPhone")
        let files = try #require(manifest["files"] as? [String: [[String: Any]]])
        #expect(files["DCIM/100APPLE/IMG_0002.MOV"]?.first?["backup_path"] as? String == "DCIM/100APPLE/IMG_0002.MOV")
    }

    @Test func rerunDoesNotFetchFilesAlreadyBackedUp() async throws {
        let f = try DeviceFixture()
        _ = try await f.backup()
        let second = try await f.backup()
        #expect(second.copied == 0)
        #expect(second.unchanged == 2)
        #expect(f.device.fetches("DCIM/100APPLE/IMG_0001.HEIC") == 1)
    }

    @Test func missingBackupCopyIsFetchedAgain() async throws {
        let f = try DeviceFixture()
        let first = try await f.backup()
        try FileManager.default.removeItem(at: first.backupDirectory.appendingPathComponent("DCIM/100APPLE/IMG_0001.HEIC"))
        let second = try await f.backup()
        #expect(second.copied == 1)
        #expect(second.unchanged == 1)
    }

    @Test func changedDeviceFileBecomesAConflictCopy() async throws {
        let f = try DeviceFixture()
        let first = try await f.backup()
        f.device.set("DCIM/100APPLE/IMG_0001.HEIC", Data("edited heic, longer".utf8))
        let second = try await f.backup()
        #expect(second.copied == 1)
        let folder = first.backupDirectory.appendingPathComponent("DCIM/100APPLE")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.hasPrefix("IMG_0001.conflict-") && $0.hasSuffix(".HEIC") })
        #expect(try Data(contentsOf: folder.appendingPathComponent("IMG_0001.HEIC")) == Data("simulated heic".utf8))
    }

    @Test func incompleteAndFailedDownloadsAreReportedWithoutPublishing() async throws {
        let f = try DeviceFixture()
        f.device.truncate = ["DCIM/100APPLE/IMG_0001.HEIC"]
        f.device.failing = ["DCIM/100APPLE/IMG_0002.MOV"]
        let report = try await f.backup()
        #expect(report.copied == 0)
        #expect(report.errors.count == 2)
        #expect(!FileManager.default.fileExists(atPath: report.backupDirectory.appendingPathComponent("DCIM/100APPLE/IMG_0001.HEIC").path))

        f.device.truncate = []
        f.device.failing = []
        let retry = try await f.backup()
        #expect(retry.copied == 2)
        #expect(retry.errors.isEmpty)
    }

    @Test func cancellationStopsAndResumes() async throws {
        var contents: [String: Data] = [:]
        for index in 0..<6 { contents["DCIM/IMG_\(index).JPG"] = Data("photo \(index)".utf8) }
        let f = try DeviceFixture(contents)
        let counter = Counter()
        let report = try await f.backup(isCancelled: { counter.value >= 2 }, progress: { _, _, _, _ in counter.increment() })
        #expect(report.cancelled)
        #expect(report.copied == 2)
        let resumed = try await f.backup()
        #expect(resumed.unchanged == 2)
        #expect(resumed.copied == 4)
    }

    @Test func stagingHappensOutsideTheBackupFolderAndIsCleanedUp() async throws {
        let f = try DeviceFixture()
        let parent = f.root.appendingPathComponent("local-staging")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // A leftover from an exited process is removed; one from a running process is kept.
        let stale = "PhonePhotoBackup-staging-999999-old", live = "PhonePhotoBackup-staging-\(getpid())-live"
        for name in [stale, live] {
            try FileManager.default.createDirectory(at: parent.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let report = try await BackupEngine.runStaged(f.plan(), fetch: f.device.fetch, stagingParent: parent)
        #expect(report.copied > 0)
        #expect(report.errors.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == [live])
    }

    @Test func crossVolumeCopyIsVerifiedAndKeepsDates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppb-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("staged.bin").path
        let bytes = Data((0..<(9 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }) // spans two 8 MB chunks
        try bytes.write(to: URL(fileURLWithPath: source))
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: source)
        let digest = try BackupEngine.sha256(of: source)
        let target = root.appendingPathComponent("out/DCIM/IMG_0001.HEIC").path
        try BackupEngine.copyVerified(from: source, to: target, expectedHash: digest, expected: FileSnapshot(path: source))
        #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: target)[.modificationDate] as? Date == past)
        #expect(throws: BackupError(.verificationFailed)) {
            try BackupEngine.copyVerified(from: source, to: target + "-2", expectedHash: String(repeating: "0", count: 64),
                                          expected: FileSnapshot(path: source))
        }
        #expect(!FileManager.default.fileExists(atPath: target + "-2"))
    }

    @Test func devicePathsStayInsideTheBackupFolder() {
        #expect(BackupEngine.devicePath(["DCIM", "100APPLE", "IMG_0001.HEIC"]) == "DCIM/100APPLE/IMG_0001.HEIC")
        #expect(BackupEngine.devicePath(["..", "a/b", "", "c:d"]) == "_/a_b/_/c_d")
    }

    @Test func duplicatePathsArePlannedOnce() throws {
        let f = try DeviceFixture()
        let files = f.device.files + f.device.files
        let plan = BackupEngine.makeDevicePlan(deviceName: "iPhone", files: files, destination: f.destination)
        #expect(plan.files.count == 2)
        #expect(plan.sourceDirectory == nil)
    }
}
