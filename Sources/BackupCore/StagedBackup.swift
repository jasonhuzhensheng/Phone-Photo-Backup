import Darwin
import Foundation

/// Backups from a source that is not a mounted folder, such as a phone connected over USB.
///
/// Each file is fetched into a staging folder on the Mac's own disk, checked against the size the
/// device reported and hashed with SHA-256. If the backup is on the same volume it is moved into
/// place; otherwise it is copied with large writes, verified again while writing, flushed and then
/// published without overwriting anything. (ImageCaptureCore writes very slowly straight onto
/// exFAT drives — about a tenth of the speed it reaches on the internal APFS disk — so it never
/// downloads directly to the backup volume.) Skip, conflict-copy and manifest rules
/// are the same as for folder backups. Nothing on the device is modified or deleted.
extension BackupEngine {
    /// Staging folder used inside the backup folder by earlier versions; removed if found.
    public static let stagingFolderName = ".phone-photo-backup-staging"
    /// Prefix of the per-run staging folder created in the temporary directory.
    static let localStagingPrefix = "PhonePhotoBackup-staging-"
    /// File inside a device backup folder holding the identifier of the device it belongs to.
    public static let deviceMarkerName = ".phone-photo-backup-device"

    /// Fetches one file into `directory` and returns the URL of the file it wrote there.
    public typealias Fetch = @Sendable (_ file: PlannedFile, _ directory: URL) async throws -> URL

    /// Plans a backup of files listed by a device. The backup folder is `<device name>_backup`.
    /// Phones often share a name ("iPhone"), so each folder is tied to one device: a folder that
    /// belongs to another device, or to a folder backup, is never reused; `<name> 2_backup`,
    /// `<name> 3_backup`… are used instead. Other backups on the destination and `references`
    /// are indexed so files already stored there are not stored again.
    public static func makeDevicePlan(deviceName: String, deviceID: String, files: [PlannedFile], destination: URL,
                                      references: [URL] = []) -> BackupPlan {
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
            totalBytes: sorted.reduce(0) { $0 + $1.size },
            existing: ExistingBackups.load(destination: destinationPath, excluding: name + "_backup",
                                           references: references)
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
        stagingParent: URL = FileManager.default.temporaryDirectory,
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

        // Leftovers from interrupted runs (and from versions that staged inside the backup folder).
        try? FileManager.default.removeItem(atPath: (backupDir as NSString).appendingPathComponent(stagingFolderName))
        removeStaleStaging(in: stagingParent)
        let staging = stagingParent.appendingPathComponent(
            "\(localStagingPrefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let sameVolume = (try? FS.lstatInfo(staging.path).st_dev) == (try? FS.lstatInfo(backupDir).st_dev)

        var report = BackupReport(backupDirectory: plan.backupDirectory)
        var stored = manifest.storedPathsByDigest()
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
                    outcome = try place(downloaded, as: file, backupDir: backupDir, sameVolume: sameVolume,
                                        existing: plan.existing, stored: &stored, manifest: &manifest, report: &report)
                }
                report.count(outcome, size: file.size)
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

    /// Removes staging folders left in `parent` by runs whose process has exited
    /// (`PhonePhotoBackup-staging-<pid>-<uuid>`). Folders of running processes are left alone.
    static func removeStaleStaging(in parent: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(localStagingPrefix) {
            let rest = name.dropFirst(localStagingPrefix.count)
            if let pid = Int32(rest.prefix { $0 != "-" }), pid > 0, kill(pid, 0) == 0 || errno == EPERM {
                continue // that process is still running
            }
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    /// Verifies a fetched file and moves or copies it to its place in the backup folder.
    private static func place(
        _ downloaded: String, as file: PlannedFile, backupDir: String, sameVolume: Bool,
        existing: ExistingBackups, stored: inout [String: String], manifest: inout Manifest, report: inout BackupReport
    ) throws -> FileOutcome {
        let info = try FS.lstatInfo(downloaded)
        let size = Int64(info.st_size)
        guard FS.isRegularFile(info), size == file.size else { throw BackupError(.downloadIncomplete) }
        if sameVolume { try FS.flush(downloaded) }
        let digest = try sha256(of: downloaded)

        var target = (backupDir as NSString).appendingPathComponent(file.relativePath)
        var outcome = FileOutcome.unchanged
        if try existsAsSameFile(target, digest: digest) {
            // already in this backup
        } else if let own = storedCopy(stored[digest], in: backupDir, size: size) {
            // Already recorded under another path (the phone renamed a folder, or two names share
            // the same bytes). A "../other_backup/…" path means it lives in another backup.
            target = own
            if stored[digest]!.hasPrefix("../") { outcome = .duplicate }
        } else if let copy = existing.copy(withDigest: digest, size: size) {
            target = copy
            outcome = .duplicate
        } else {
            if try FS.lstatIfExists(target) != nil {
                target = try conflictPath(for: target, digest: digest)
            }
            if try !existsAsSameFile(target, digest: digest) {
                try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                if sameVolume {
                    try FS.publishExclusive(downloaded, to: target)
                } else {
                    try copyVerified(from: downloaded, to: target, expectedHash: digest, expected: FileSnapshot(info))
                }
                outcome = .copied
            }
        }
        let backupRelative = relativePath(of: target, from: backupDir)
        manifest.record(file.relativePath, sha256: digest, size: size, backupPath: backupRelative)
        if stored[digest] == nil { stored[digest] = backupRelative }
        return outcome
    }
}
