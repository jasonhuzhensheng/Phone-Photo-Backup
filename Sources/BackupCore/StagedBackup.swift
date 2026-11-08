import Darwin
import Foundation

/// Backups from a source that is not a mounted folder, such as a phone connected over USB.
///
/// Each file is fetched into a staging folder inside the backup folder (so the final move stays on
/// one volume), checked against the size the device reported, flushed to disk, hashed with SHA-256
/// and then moved into place without overwriting anything. Skip, conflict-copy and manifest rules
/// are the same as for folder backups. Nothing on the device is modified or deleted.
extension BackupEngine {
    public static let stagingFolderName = ".phone-photo-backup-staging"
    /// File inside a device backup folder holding the identifier of the device it belongs to.
    public static let deviceMarkerName = ".phone-photo-backup-device"

    /// Fetches one file into `directory` and returns the URL of the file it wrote there.
    public typealias Fetch = @Sendable (_ file: PlannedFile, _ directory: URL) async throws -> URL

    /// Plans a backup of files listed by a device. The backup folder is `<device name>_backup`.
    /// Phones often share a name ("iPhone"), so each folder is tied to one device: a folder that
    /// belongs to another device, or to a folder backup, is never reused; `<name> 2_backup`,
    /// `<name> 3_backup`… are used instead.
    public static func makeDevicePlan(deviceName: String, deviceID: String, files: [PlannedFile], destination: URL) -> BackupPlan {
        let destinationPath = FS.canonicalPath(destination.path)
        let (name, backupPath) = deviceFolder(name: safeFolderName(deviceName), id: deviceID, in: destinationPath)
        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.relativePath).inserted }
        let sorted = unique.sorted {
            let a = $0.relativePath.lowercased(), b = $1.relativePath.lowercased()
            return a == b ? $0.relativePath < $1.relativePath : a < b
        }
        var plan = BackupPlan(
            sourceName: name,
            sourceDirectory: nil,
            backupDirectory: URL(fileURLWithPath: backupPath, isDirectory: true),
            files: sorted,
            totalBytes: sorted.reduce(0) { $0 + $1.size }
        )
        plan.deviceID = deviceID
        return plan
    }

    /// The first `<name>[ n]_backup` folder that is free or already belongs to `id`.
    static func deviceFolder(name: String, id: String, in destinationPath: String) -> (name: String, path: String) {
        var number = 1
        while true {
            let candidate = number == 1 ? name : "\(name) \(number)"
            let path = (destinationPath as NSString).appendingPathComponent(candidate + "_backup")
            let marker = (path as NSString).appendingPathComponent(deviceMarkerName)
            if (try? FS.lstatIfExists(path)) == nil {
                return (candidate, path)
            }
            if let owner = try? String(contentsOfFile: marker, encoding: .utf8),
               owner.trimmingCharacters(in: .whitespacesAndNewlines) == id {
                return (candidate, path)
            }
            number += 1
        }
    }

    /// Joins path components reported by a device into a relative path that always stays inside
    /// the backup folder: separators and control characters are replaced, and empty, `.` and `..`
    /// components become `_`.
    public static func devicePath(_ components: [String]) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(CharacterSet(charactersIn: "\u{00}"..."\u{1F}"))
        return components.map { component in
            let cleaned = String(String.UnicodeScalarView(component.unicodeScalars.map { forbidden.contains($0) ? "_" : $0 }))
            return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "_" : cleaned
        }.joined(separator: "/")
    }

    /// Backs up every planned file using `fetch` to read it from the source.
    ///
    /// A file is not fetched again when the manifest already records a version of it with the same
    /// size and that copy is still present in the backup folder, so re-running after a stop is quick.
    public static func runStaged(
        _ plan: BackupPlan,
        fetch: Fetch,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        progress: BackupProgress? = nil
    ) async throws -> BackupReport {
        let backupDir = plan.backupDirectory.path
        try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        let manifestPath = (backupDir as NSString).appendingPathComponent(manifestName)
        var manifest = try Manifest.load(from: manifestPath, sourceName: plan.sourceName)
        if let deviceID = plan.deviceID {
            let marker = (backupDir as NSString).appendingPathComponent(deviceMarkerName)
            if (try? FS.lstatIfExists(marker)) == nil {
                try FS.writeAtomically(Data((deviceID + "\n").utf8), to: marker)
            }
        }

        let staging = URL(fileURLWithPath: backupDir, isDirectory: true)
            .appendingPathComponent(stagingFolderName, isDirectory: true)
        try? FileManager.default.removeItem(at: staging) // leftovers from an interrupted run
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var report = BackupReport(backupDirectory: plan.backupDirectory)
        let total = plan.files.count

        for (offset, file) in plan.files.enumerated() {
            if isCancelled() {
                report.cancelled = true
                break
            }
            var outcome = FileOutcome.error
            do {
                if let index = recordedCopy(of: file, in: manifest, backupDir: backupDir) {
                    manifest.touch(file.relativePath, version: index)
                    outcome = .unchanged
                } else {
                    let downloaded = try await fetch(file, staging).path
                    defer { unlink(downloaded) } // no-op once the file has been moved into place
                    guard FS.contains(staging.path, downloaded) else { throw BackupError(.downloadIncomplete) }
                    outcome = try place(downloaded, as: file, backupDir: backupDir, manifest: &manifest, report: &report)
                }
                if outcome == .copied { report.copied += 1 } else { report.unchanged += 1 }
            } catch {
                if error is CancellationError || isCancelled() {
                    report.cancelled = true
                    break
                }
                report.errors.append("\(file.relativePath): \(error.localizedDescription)")
            }
            progress?(offset + 1, total, file, outcome)
        }

        manifest.updatedAt = Manifest.timestamp()
        do {
            try manifest.write(to: manifestPath)
        } catch {
            throw BackupError(.manifestNotSaved(error.localizedDescription))
        }
        return report
    }

    /// Index of a manifest version of `file` with the same size whose copy still exists.
    static func recordedCopy(of file: PlannedFile, in manifest: Manifest, backupDir: String) -> Int? {
        guard let versions = manifest.files[file.relativePath] else { return nil }
        for index in versions.indices.reversed() where versions[index].sizeBytes == file.size {
            let path = (backupDir as NSString).appendingPathComponent(versions[index].backupPath)
            if let info = try? FS.lstatIfExists(path), FS.isRegularFile(info), Int64(info.st_size) == file.size {
                return index
            }
        }
        return nil
    }

    /// Verifies a fetched file and moves it to its place in the backup folder.
    private static func place(
        _ downloaded: String, as file: PlannedFile, backupDir: String,
        manifest: inout Manifest, report: inout BackupReport
    ) throws -> FileOutcome {
        let info = try FS.lstatInfo(downloaded)
        let size = Int64(info.st_size)
        guard FS.isRegularFile(info), size == file.size else { throw BackupError(.downloadIncomplete) }
        try FS.flush(downloaded)
        let digest = try sha256(of: downloaded)

        var target = (backupDir as NSString).appendingPathComponent(file.relativePath)
        var outcome = FileOutcome.unchanged
        if try !existsAsSameFile(target, digest: digest) {
            if try FS.lstatIfExists(target) != nil {
                target = try conflictPath(for: target, digest: digest)
            }
            if try !existsAsSameFile(target, digest: digest) {
                try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try FS.publishExclusive(downloaded, to: target)
                outcome = .copied
                report.bytesCopied += size
            }
        }
        manifest.record(file.relativePath, sha256: digest, size: size,
                        backupPath: String(target.dropFirst(backupDir.count + 1)))
        return outcome
    }
}
