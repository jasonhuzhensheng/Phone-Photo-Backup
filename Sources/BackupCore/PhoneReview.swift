import Foundation

/// A file on the phone as seen by the review step.
public struct PhoneItem: Sendable, Hashable, Identifiable {
    public let relativePath: String
    public let size: Int64
    public let date: Date?
    /// Video length in seconds, when known.
    public let duration: Double?

    public var id: String { relativePath }
    public var filename: String { (relativePath as NSString).lastPathComponent }
    public var isVideo: Bool { PhoneReview.videoExtensions.contains((relativePath as NSString).pathExtension.lowercased()) }

    public init(relativePath: String, size: Int64, date: Date?, duration: Double? = nil) {
        self.relativePath = relativePath
        self.size = size
        self.date = date
        self.duration = duration
    }
}

/// Files with identical contents. `files[0]` is the copy suggested to keep (the oldest).
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    public let sha256: String
    public let files: [PhoneItem]

    public var id: String { sha256 }
    public var keep: PhoneItem { files[0] }
    public var extras: [PhoneItem] { Array(files.dropFirst()) }
    /// Space freed by deleting every copy except one.
    public var reclaimable: Int64 { extras.reduce(0) { $0 + $1.size } }
}

/// The review before a backup: the largest videos and exact duplicates, so the user can decide
/// what to delete from the phone. Deciding and checking is pure logic; the app does the deleting.
public enum PhoneReview {
    static let videoExtensions: Set<String> = PhotosImport.videoExtensions

    /// Videos sorted by size, largest first, at least `minimumSize` bytes, at most `limit` of them.
    public static func largestVideos(_ items: [PhoneItem], minimumSize: Int64 = 50 << 20, limit: Int = 100) -> [PhoneItem] {
        Array(items.filter { $0.isVideo && $0.size >= minimumSize }
            .sorted { $0.size == $1.size ? $0.relativePath < $1.relativePath : $0.size > $1.size }
            .prefix(limit))
    }

    /// Photos and videos that share their exact size with another one. Only these can be
    /// duplicates, so only these need to be read from the phone and hashed.
    public static func duplicateCandidates(_ items: [PhoneItem]) -> [PhoneItem] {
        let media = items.filter { $0.size > 0 && PhotosImport.isMedia($0.relativePath) }
        let counts = Dictionary(grouping: media, by: \.size).filter { $0.value.count > 1 }
        return counts.values.flatMap { $0 }.sorted { $0.relativePath < $1.relativePath }
    }

    /// Hashes every candidate with `hash` and groups identical contents. Groups are sorted by the
    /// space they would free; inside a group the oldest copy comes first.
    public static func findDuplicates(
        _ items: [PhoneItem],
        hash: @Sendable (PhoneItem) async throws -> String,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws -> [DuplicateGroup] {
        let candidates = duplicateCandidates(items)
        var byHash: [String: [PhoneItem]] = [:]
        for (index, item) in candidates.enumerated() {
            try Task.checkCancellation()
            byHash[try await hash(item), default: []].append(item)
            progress?(index + 1, candidates.count)
        }
        return byHash.compactMap { sha, files -> DuplicateGroup? in
            guard files.count > 1 else { return nil }
            let ordered = files.sorted {
                switch ($0.date, $1.date) {
                case let (a?, b?) where a != b: return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.relativePath < $1.relativePath
                }
            }
            return DuplicateGroup(sha256: sha, files: ordered)
        }
        .sorted { $0.reclaimable == $1.reclaimable ? $0.sha256 < $1.sha256 : $0.reclaimable > $1.reclaimable }
    }

    /// Splits `items` into those with a complete copy in `backupDirectory` (recorded in its manifest
    /// with the same size, and the copy present with that size) and those without one.
    /// Only the first group may be deleted from the phone after a backup.
    public static func backedUp(_ items: [PhoneItem], in backupDirectory: URL) -> (safe: [PhoneItem], missing: [PhoneItem]) {
        let manifestPath = backupDirectory.appendingPathComponent(BackupEngine.manifestName).path
        guard let manifest = try? Manifest.read(from: manifestPath) else { return ([], items) }
        var safe: [PhoneItem] = [], missing: [PhoneItem] = []
        for item in items {
            if copy(of: item, manifest: manifest, in: backupDirectory) != nil { safe.append(item) } else { missing.append(item) }
        }
        return (safe, missing)
    }

    /// The complete backup copy of `item` in `backupDirectory`, if there is one. Used to preview a
    /// video from the disk instead of streaming it from the phone.
    public static func backupCopy(of item: PhoneItem, in backupDirectory: URL) -> URL? {
        let manifestPath = backupDirectory.appendingPathComponent(BackupEngine.manifestName).path
        guard let manifest = try? Manifest.read(from: manifestPath) else { return nil }
        return copy(of: item, manifest: manifest, in: backupDirectory)
    }

    private static func copy(of item: PhoneItem, manifest: Manifest, in backupDirectory: URL) -> URL? {
        for version in (manifest.files[item.relativePath] ?? []).reversed() where version.sizeBytes == item.size {
            let path = (backupDirectory.path as NSString).appendingPathComponent(version.backupPath)
            guard let info = try? FS.lstatIfExists(path), FS.isRegularFile(info), Int64(info.st_size) == item.size else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// SHA-256 of each item's backup copy (the manifest version with the same size), by path.
    public static func backupHashes(of items: [PhoneItem], in backupDirectory: URL) -> [String: String] {
        let manifestPath = backupDirectory.appendingPathComponent(BackupEngine.manifestName).path
        guard let manifest = try? Manifest.read(from: manifestPath) else { return [:] }
        var hashes: [String: String] = [:]
        for item in items {
            if let version = (manifest.files[item.relativePath] ?? []).last(where: { $0.sizeBytes == item.size }) {
                hashes[item.relativePath] = version.sha256
            }
        }
        return hashes
    }
}
