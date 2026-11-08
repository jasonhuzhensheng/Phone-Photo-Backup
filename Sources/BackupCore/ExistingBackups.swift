import Foundation

/// Index of files that are already backed up somewhere, so they are not stored again:
/// - every other `*_backup` folder with a manifest on the same destination, and
/// - folders the user chose to compare with ("reference folders"): backups made by this app
///   (their manifest is used) or any plain folder of photos.
///
/// - Before a backup, `likelyCopy(of:)` matches by file name + size (no reading needed) to preview
///   how much is already backed up.
/// - During a backup, `copy(withDigest:size:)` matches by SHA-256, which is exact and also catches
///   renamed files. Only that exact match skips a file. Files in plain folders are hashed only when
///   a file of exactly the same size comes up, and each hash is computed once.
///
/// (ImageCaptureCore can fingerprint files on a phone and on the Mac, but the two use different
/// schemes, so they cannot be compared with each other.)
public final class ExistingBackups: @unchecked Sendable {
    /// SHA-256 → absolute path of a stored copy (from manifests).
    private var byDigest: [String: String] = [:]
    /// "name|size" → absolute path of a stored copy.
    private var byNameSize: [String: String] = [:]
    /// Size → absolute paths of files in plain reference folders (no manifest).
    private var plainBySize: [Int64: [String]] = [:]
    /// Path → SHA-256 of plain files hashed so far.
    private var plainDigests: [String: String] = [:]
    private let lock = NSLock()

    /// Number of files indexed.
    public private(set) var fileCount = 0
    /// Display names of the backups and folders that were indexed.
    public private(set) var folders: [String] = []

    public init() {}

    /// Indexes the backups in `destination` (including `excludedFolder`, the backup being made, which
    /// is never taken from `references`) and the `references` the user chose. Unreadable manifests and folders are skipped.
    public static func load(destination: String, excluding excludedFolder: String,
                            references: [URL] = []) -> ExistingBackups {
        let index = ExistingBackups()
        let excluded = (destination as NSString).appendingPathComponent(excludedFolder)
        // The backup being made is included too, so the preview counts what it already holds
        // (paths on a phone can change between sessions). During the backup its own manifest is
        // checked first, so its files count as unchanged, not as duplicates.
        for folder in index.manifestFolders(in: destination) {
            index.addManifest(of: folder, name: (folder as NSString).lastPathComponent)
        }
        for reference in references {
            let root = FS.canonicalPath(reference.path)
            guard root != excluded, !FS.contains(excluded, root) else { continue }
            if index.addManifest(of: root, name: (root as NSString).lastPathComponent) { continue }
            let inside = index.manifestFolders(in: root).filter { $0 != excluded }
            if !inside.isEmpty {
                for folder in inside where !index.folders.contains((folder as NSString).lastPathComponent) {
                    index.addManifest(of: folder, name: (folder as NSString).lastPathComponent)
                }
            } else {
                index.addPlainFolder(root)
            }
        }
        return index
    }

    /// `*_backup` subfolders of `parent` that contain a manifest.
    private func manifestFolders(in parent: String) -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []).sorted()
        return names.filter { $0.hasSuffix("_backup") }.map { (parent as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(BackupEngine.manifestName)) }
    }

    /// Adds the files recorded in `base`'s manifest. Returns false when there is no readable manifest.
    @discardableResult
    private func addManifest(of base: String, name: String) -> Bool {
        let manifestPath = (base as NSString).appendingPathComponent(BackupEngine.manifestName)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return false }
        folders.append(name)
        for versions in manifest.files.values {
            for version in versions {
                // Resolve "../other_backup/…" entries (files that were themselves duplicates).
                let path = BackupEngine.normalized((base as NSString).appendingPathComponent(version.backupPath))
                if byDigest[version.sha256] == nil {
                    byDigest[version.sha256] = path
                    fileCount += 1
                }
                let key = "\((path as NSString).lastPathComponent)|\(version.sizeBytes)"
                if byNameSize[key] == nil { byNameSize[key] = path }
            }
        }
        return true
    }

    /// Adds every regular file under `root` (symlinks are not followed; hidden files are skipped).
    private func addPlainFolder(_ root: String) {
        var stack = [root]
        var added = 0
        while let directory = stack.popLast() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where !name.hasPrefix(".") {
                let path = (directory as NSString).appendingPathComponent(name)
                guard let info = try? FS.lstatInfo(path) else { continue }
                if FS.isDirectory(info) {
                    stack.append(path)
                } else if FS.isRegularFile(info) {
                    let size = Int64(info.st_size)
                    plainBySize[size, default: []].append(path)
                    let key = "\(name)|\(size)"
                    if byNameSize[key] == nil { byNameSize[key] = path }
                    added += 1
                }
            }
        }
        fileCount += added
        folders.append((root as NSString).lastPathComponent)
    }

    public var isEmpty: Bool { fileCount == 0 }

    /// A stored file with the same name and size, if any. A strong hint, not proof.
    public func likelyCopy(of file: PlannedFile) -> String? {
        byNameSize["\((file.relativePath as NSString).lastPathComponent)|\(file.size)"]
    }

    /// A stored file with exactly this content that is still present with the expected size.
    func copy(withDigest digest: String, size: Int64) -> String? {
        if let path = byDigest[digest], Self.present(path, size: size) { return path }
        for path in plainBySize[size] ?? [] {
            let known = lock.withLock { plainDigests[path] }
            let fileDigest = known ?? (try? BackupEngine.sha256(of: path))
            if known == nil, let fileDigest { lock.withLock { plainDigests[path] = fileDigest } }
            if fileDigest == digest, Self.present(path, size: size) { return path }
        }
        return nil
    }

    private static func present(_ path: String, size: Int64) -> Bool {
        guard let info = try? FS.lstatIfExists(path), FS.isRegularFile(info) else { return false }
        return Int64(info.st_size) == size
    }
}

extension BackupPlan {
    /// Files that most likely are already in another backup (same name and size), and their size.
    public var likelyDuplicates: (count: Int, bytes: Int64) {
        guard !existing.isEmpty else { return (0, 0) }
        var count = 0, bytes: Int64 = 0
        for file in files where existing.likelyCopy(of: file) != nil {
            count += 1
            bytes += file.size
        }
        return (count, bytes)
    }
}

extension BackupEngine {
    /// Path of `target` relative to `backupDir`, e.g. "../other_backup/DCIM/IMG_0001.HEIC".
    static func relativePath(of target: String, from backupDir: String) -> String {
        let base = normalized(backupDir).split(separator: "/").map(String.init)
        let path = normalized(target).split(separator: "/").map(String.init)
        var common = 0
        while common < base.count, common < path.count, base[common] == path[common] { common += 1 }
        let ups = Array(repeating: "..", count: base.count - common)
        return (ups + path[common...]).joined(separator: "/")
    }

    /// Absolute path of a copy recorded in this backup's manifest, if it is still there with `size`.
    static func storedCopy(_ relative: String?, in backupDir: String, size: Int64) -> String? {
        guard let relative else { return nil }
        let path = normalized((backupDir as NSString).appendingPathComponent(relative))
        guard let info = try? FS.lstatIfExists(path), FS.isRegularFile(info), Int64(info.st_size) == size else { return nil }
        return path
    }

    /// Resolves "." and ".." in an absolute path without touching anything else. (Foundation's
    /// standardizing also drops a leading "/private", which breaks comparisons with real paths.)
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
}

extension BackupReport {
    /// Adds one processed file to the totals.
    mutating func count(_ outcome: FileOutcome, size: Int64) {
        switch outcome {
        case .copied:
            copied += 1
            bytesCopied += size
        case .unchanged:
            unchanged += 1
        case .duplicate:
            duplicates += 1
            duplicateBytes += size
        case .error:
            break
        }
    }
}
