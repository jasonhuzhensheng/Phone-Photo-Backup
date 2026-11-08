import CryptoKit
import Foundation

/// A validation or backup error that is safe to show in the UI.
public struct BackupError: LocalizedError, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case sourceMissing
        case sourceNotFolder
        case overlap
        case cannotScan(String)
        case sourceChanged
        case verificationFailed
        case manifestUnreadable
        case manifestMismatch
        case manifestNotSaved(String)
        case downloadIncomplete
    }

    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }

    public var errorDescription: String? {
        switch kind {
        case .sourceMissing:
            String(localized: "The source folder does not exist or cannot be opened.")
        case .sourceNotFolder:
            String(localized: "Choose a source folder containing the exported phone files.")
        case .overlap:
            String(localized: "Choose a backup location that does not overlap the source folder.")
        case .cannotScan(let detail):
            String(localized: "Cannot read the source folder: \(detail)")
        case .sourceChanged:
            String(localized: "The source file changed during backup; run the backup again.")
        case .verificationFailed:
            String(localized: "The copied file did not pass SHA-256 verification.")
        case .manifestUnreadable:
            String(localized: "The existing backup manifest is unreadable; no files were changed.")
        case .manifestMismatch:
            String(localized: "The existing manifest does not match this backup; no files were changed.")
        case .manifestNotSaved(let detail):
            String(localized: "Files were copied, but the manifest could not be saved: \(detail)")
        case .downloadIncomplete:
            String(localized: "The file read from the device is incomplete; run the backup again.")
        }
    }
}

public struct PlannedFile: Sendable, Hashable {
    /// Path relative to the source folder, using "/" separators.
    public let relativePath: String
    public let size: Int64

    public init(relativePath: String, size: Int64) {
        self.relativePath = relativePath
        self.size = size
    }
}

public struct BackupPlan: Sendable {
    /// Name stored in the manifest: the source folder's name, or the device name.
    public let sourceName: String
    /// The source folder, or nil when the files come from a connected device.
    public let sourceDirectory: URL?
    /// Stable identifier of the source device; nil for folders.
    public var deviceID: String? = nil
    public let backupDirectory: URL
    public let files: [PlannedFile]
    public let totalBytes: Int64
}

public enum FileOutcome: String, Sendable {
    case copied, unchanged, error
}

public struct BackupReport: Sendable {
    public let backupDirectory: URL
    public var copied = 0
    public var unchanged = 0
    public var bytesCopied: Int64 = 0
    public var errors: [String] = []
    /// True when the user stopped the backup before every file was processed.
    public var cancelled = false
}

public typealias BackupProgress = @Sendable (_ index: Int, _ total: Int, _ file: PlannedFile, _ outcome: FileOutcome) -> Void

/// Safe, incremental, byte-for-byte backups of an exported phone-media folder.
/// Never modifies or deletes anything in the source folder.
public enum BackupEngine {
    public static let manifestName = ".phone-photo-backup.json"
    public static let schemaVersion = 1
    static let chunkSize = 1 << 20

    // MARK: Planning

    /// Validates the two folders and lists every regular file, without following symlinks.
    public static func makePlan(source: URL, destination: URL) throws -> BackupPlan {
        let sourcePath: String
        do {
            sourcePath = try FS.realPath((source.path as NSString).expandingTildeInPath)
        } catch {
            throw BackupError(.sourceMissing)
        }
        guard let info = try? FS.lstatInfo(sourcePath), FS.isDirectory(info) else {
            throw BackupError(.sourceNotFolder)
        }

        let destinationPath = FS.canonicalPath(destination.path)
        let sourceName = (sourcePath as NSString).lastPathComponent
        let backupPath = (destinationPath as NSString).appendingPathComponent(safeFolderName(sourceName) + "_backup")
        if FS.contains(sourcePath, backupPath) || FS.contains(backupPath, sourcePath) {
            throw BackupError(.overlap)
        }

        var found: [PlannedFile] = []
        try walk(sourcePath, relative: "", into: &found)
        found.sort {
            let a = $0.relativePath.lowercased(), b = $1.relativePath.lowercased()
            return a == b ? $0.relativePath < $1.relativePath : a < b
        }
        return BackupPlan(
            sourceName: sourceName,
            sourceDirectory: URL(fileURLWithPath: sourcePath, isDirectory: true),
            backupDirectory: URL(fileURLWithPath: backupPath, isDirectory: true),
            files: found,
            totalBytes: found.reduce(0) { $0 + $1.size }
        )
    }

    private static func walk(_ directory: String, relative: String, into found: inout [PlannedFile]) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch {
            throw BackupError(.cannotScan(error.localizedDescription))
        }
        for name in names {
            let path = (directory as NSString).appendingPathComponent(name)
            let rel = relative.isEmpty ? name : relative + "/" + name
            let info: stat
            do { info = try FS.lstatInfo(path) } catch { throw BackupError(.cannotScan(error.localizedDescription)) }
            if FS.isDirectory(info) {
                try walk(path, relative: rel, into: &found)
            } else if FS.isRegularFile(info) {
                found.append(PlannedFile(relativePath: rel, size: Int64(info.st_size)))
            }
            // Symlinks, sockets and devices are skipped.
        }
    }

    static func safeFolderName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*").union(CharacterSet(charactersIn: "\u{00}"..."\u{1F}"))
        let replaced = String(String.UnicodeScalarView(name.unicodeScalars.map { forbidden.contains($0) ? "_" : $0 }))
        let cleaned = replaced.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "Phone Import" : cleaned
    }

    // MARK: Backup

    /// Copies and verifies every planned file. Errors on individual files are collected in the
    /// report; manifest problems abort before anything is written.
    public static func run(
        _ plan: BackupPlan,
        isCancelled: @Sendable () -> Bool = { false },
        progress: BackupProgress? = nil
    ) throws -> BackupReport {
        guard let sourceDir = plan.sourceDirectory?.path else { throw BackupError(.sourceMissing) }
        let backupDir = plan.backupDirectory.path
        try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        let manifestPath = (backupDir as NSString).appendingPathComponent(manifestName)
        var manifest = try Manifest.load(from: manifestPath, sourceName: plan.sourceName)
        var report = BackupReport(backupDirectory: plan.backupDirectory)
        let total = plan.files.count

        for (offset, file) in plan.files.enumerated() {
            if isCancelled() {
                report.cancelled = true
                break
            }
            var outcome = FileOutcome.error
            do {
                let source = (sourceDir as NSString).appendingPathComponent(file.relativePath)
                let before = try FileSnapshot(path: source)
                let digest = try sha256(of: source)
                guard try FileSnapshot(path: source) == before else { throw BackupError(.sourceChanged) }

                var target = (backupDir as NSString).appendingPathComponent(file.relativePath)
                if try existsAsSameFile(target, digest: digest) {
                    outcome = .unchanged
                } else {
                    if try FS.lstatIfExists(target) != nil {
                        target = try conflictPath(for: target, digest: digest)
                    }
                    if try existsAsSameFile(target, digest: digest) {
                        outcome = .unchanged
                    } else {
                        try copyVerified(from: source, to: target, expectedHash: digest, expected: before)
                        outcome = .copied
                        report.bytesCopied += before.size
                    }
                }
                if outcome == .copied { report.copied += 1 } else { report.unchanged += 1 }

                manifest.record(file.relativePath, sha256: digest, size: before.size,
                                backupPath: String(target.dropFirst(backupDir.count + 1)))
            } catch {
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

    // MARK: Helpers

    static func sha256(of path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func existsAsSameFile(_ path: String, digest: String) throws -> Bool {
        guard let info = try FS.lstatIfExists(path), FS.isRegularFile(info) else { return false }
        return try sha256(of: path) == digest
    }

    /// `photo.jpg` → `photo.conflict-1a2b3c4d.jpg` (or `-2`, `-3`… if that name is taken by other bytes).
    static func conflictPath(for target: String, digest: String) throws -> String {
        let directory = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        let tag = String(digest.prefix(8))
        var counter = 1
        while true {
            let candidateName = counter == 1 ? "\(stem).conflict-\(tag)\(suffix)" : "\(stem).conflict-\(tag)-\(counter)\(suffix)"
            let candidate = (directory as NSString).appendingPathComponent(candidateName)
            if try FS.lstatIfExists(candidate) == nil || (try? existsAsSameFile(candidate, digest: digest)) == true {
                return candidate
            }
            counter += 1
        }
    }

    private static func copyVerified(from source: String, to target: String, expectedHash: String, expected: FileSnapshot) throws {
        let directory = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let name = (target as NSString).lastPathComponent
        let temporary = (directory as NSString).appendingPathComponent(".\(name).\(UUID().uuidString.lowercased()).part")
        do {
            let writer = try FS.createExclusive(temporary)
            let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: source))
            defer { try? reader.close() }
            var hasher = SHA256()
            while let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
                hasher.update(data: chunk)
            }
            try writer.synchronize()
            try writer.close()
            guard try FileSnapshot(path: source) == expected else { throw BackupError(.sourceChanged) }
            guard hex(hasher.finalize()) == expectedHash else { throw BackupError(.verificationFailed) }
            try FS.copyMetadata(from: source, to: temporary)
            try FS.publishExclusive(temporary, to: target)
        } catch {
            unlink(temporary)
            throw error
        }
    }
}
