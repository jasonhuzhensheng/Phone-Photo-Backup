import Foundation

/// One backed-up file that can go into the Photos library.
public struct ImportFile: Sendable, Hashable {
    public let url: URL
    public let sha256: String
    public let size: Int64
    public var filename: String { url.lastPathComponent }

    public init(url: URL, sha256: String, size: Int64) {
        self.url = url
        self.sha256 = sha256
        self.size = size
    }
}

/// What becomes one item in Photos: a photo, a video, or a Live Photo (photo + paired video).
public struct ImportItem: Sendable, Hashable {
    public let photo: ImportFile?
    public let video: ImportFile?

    public init(photo: ImportFile?, video: ImportFile?) {
        precondition(photo != nil || video != nil)
        self.photo = photo
        self.video = video
    }

    public var isLivePhoto: Bool { photo != nil && video != nil }
    /// The file whose name and capture date identify the item.
    public var primary: ImportFile { photo ?? video! }
    public var files: [ImportFile] { [photo, video].compactMap { $0 } }
    public var size: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct ImportPlan: Sendable {
    public let items: [ImportItem]
    /// Files skipped because the same bytes appear earlier in this plan (in any backup).
    public let duplicateFiles: Int
    /// Files skipped because an earlier import already handled the same bytes.
    public let previouslyImportedFiles: Int
    /// Files that are not photos or videos (for example `.AAE` edit files).
    public let otherFiles: Int
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Remembers, by SHA-256, which backed-up files are already in the Photos library, so that
/// importing again (or importing another phone with the same photos) adds nothing twice.
/// Stored as `.phone-photo-backup-photos.json` in the backup location.
public struct ImportLedger: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        /// Photos `localIdentifier` of the asset, when this app created it.
        public var assetID: String?
        public var importedAt: String
        /// "imported" when this app added it, "existing" when it was already in Photos,
        /// "deleted" when the user deleted it from Photos in the review step.
        public var how: String

        enum CodingKeys: String, CodingKey {
            case assetID = "asset_id"
            case importedAt = "imported_at"
            case how
        }
    }

    public var schemaVersion = 1
    public var files: [String: Entry] = [:]
    /// Files handled by a direct import from a phone, by "device|path|size": the file's SHA-256,
    /// or "in-photos" when it was found in Photos without being read. Absent in older records.
    public var phoneFiles: [String: String]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case files
        case phoneFiles = "phone_files"
    }

    public init() {}

    public func contains(_ sha256: String) -> Bool { files[sha256] != nil }

    public mutating func record(_ item: ImportItem, assetID: String?, existing: Bool) {
        let now = Manifest.timestamp()
        for file in item.files {
            files[file.sha256] = Entry(assetID: assetID, importedAt: now, how: existing ? "existing" : "imported")
        }
    }

    /// Records files the user deleted from Photos, so a later import does not bring them back.
    public mutating func markDeleted(_ sha256: String) {
        files[sha256] = Entry(assetID: nil, importedAt: Manifest.timestamp(), how: "deleted")
    }

    public static func load(from destination: URL) throws -> ImportLedger {
        let url = destination.appendingPathComponent(PhotosImport.ledgerName)
        guard FileManager.default.fileExists(atPath: url.path) else { return ImportLedger() }
        do {
            return try JSONDecoder().decode(ImportLedger.self, from: Data(contentsOf: url))
        } catch {
            throw BackupError(.manifestUnreadable)
        }
    }

    public func write(to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        try FS.writeAtomically(data, to: destination.appendingPathComponent(PhotosImport.ledgerName).path)
    }
}

/// Plans importing backups into the Photos library. Pure file logic; the app does the PhotoKit part.
public enum PhotosImport {
    public static let ledgerName = ".phone-photo-backup-photos.json"

    static let imageExtensions: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "png", "gif", "tif", "tiff", "dng", "webp", "bmp",
        "raw", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf",
    ]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "avi", "mts", "m2ts"]

    public static func isMedia(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    /// Backup folders (subfolders holding a backup manifest) directly inside `destination`,
    /// sorted by name.
    public static func backupFolders(in destination: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name in
            let folder = destination.appendingPathComponent(name, isDirectory: true)
            let manifest = folder.appendingPathComponent(BackupEngine.manifestName)
            return FileManager.default.fileExists(atPath: manifest.path) ? folder : nil
        }
    }

    /// Lists every photo and video recorded in the manifests of `backupFolders`, keeps one file per
    /// SHA-256, leaves out what `ledger` already holds, and pairs Live Photos (a photo and a `.mov`
    /// with the same name in the same folder).
    public static func makePlan(backupFolders: [URL], ledger: ImportLedger) throws -> ImportPlan {
        var seen = Set<String>()
        var duplicates = 0, previous = 0, other = 0
        var items: [ImportItem] = []

        for folder in backupFolders {
            let manifest = try Manifest.read(from: folder.appendingPathComponent(BackupEngine.manifestName).path)
            var kept: [ImportFile] = []
            let versions = manifest.files.values.flatMap { $0 }.sorted { $0.backupPath < $1.backupPath }
            for version in versions {
                guard isMedia(version.backupPath) else { other += 1; continue }
                let url = folder.appendingPathComponent(version.backupPath)
                guard let info = try? FS.lstatIfExists(url.path), FS.isRegularFile(info),
                      Int64(info.st_size) == version.sizeBytes else { continue } // missing or changed copy
                if ledger.contains(version.sha256) { previous += 1; continue }
                guard seen.insert(version.sha256).inserted else { duplicates += 1; continue }
                kept.append(ImportFile(url: url, sha256: version.sha256, size: version.sizeBytes))
            }
            items += pair(kept)
        }
        return ImportPlan(items: items, duplicateFiles: duplicates, previouslyImportedFiles: previous, otherFiles: other)
    }

    /// Groups files by folder and name stem; exactly one photo plus one `.mov` becomes a Live Photo.
    static func pair(_ files: [ImportFile]) -> [ImportItem] {
        var groups: [String: [ImportFile]] = [:]
        var order: [String] = []
        for file in files {
            let key = (file.url.deletingPathExtension().path).lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(file)
        }
        var items: [ImportItem] = []
        for key in order {
            let group = groups[key]!
            let photos = group.filter { imageExtensions.contains($0.url.pathExtension.lowercased()) }
            let movies = group.filter { $0.url.pathExtension.lowercased() == "mov" }
            if photos.count == 1, movies.count == 1 {
                items.append(ImportItem(photo: photos[0], video: movies[0]))
                for file in group where file != photos[0] && file != movies[0] {
                    items.append(item(for: file))
                }
            } else {
                items += group.map(item(for:))
            }
        }
        return items
    }

    private static func item(for file: ImportFile) -> ImportItem {
        imageExtensions.contains(file.url.pathExtension.lowercased())
            ? ImportItem(photo: file, video: nil) : ImportItem(photo: nil, video: file)
    }
}

/// Recognises photos that are already in the Photos library (for example taken on the new phone
/// and synced through iCloud) by file name and capture time.
public struct LibraryIndex: Sendable {
    private struct Entry: Sendable {
        let date: Date
        let id: String?
    }

    private var entriesByStem: [String: [Entry]] = [:]
    public private(set) var count = 0

    public init() {}

    public mutating func add(filename: String, date: Date?, id: String? = nil) {
        guard let date else { return }
        entriesByStem[Self.stem(filename), default: []].append(Entry(date: date, id: id))
        count += 1
    }

    /// True when the library has an item with the same name stem (IMG_1234) whose time matches
    /// `date` within two seconds, allowing a whole-hour time-zone shift of up to 14 hours (photo
    /// metadata often has no time zone). Without a date nothing matches, so a photo is imported
    /// rather than wrongly skipped.
    public func contains(filename: String, date: Date?) -> Bool {
        guard let date, let entries = entriesByStem[Self.stem(filename)] else { return false }
        return entries.contains { Self.sameMoment(date, $0.date) }
    }

    /// The identifier of the one library item with the same name stem and a time within two
    /// seconds (no time-zone allowance). Nil when there is none or more than one, so deleting
    /// never guesses.
    public func uniqueMatch(filename: String, date: Date?) -> String? {
        guard let date, let entries = entriesByStem[Self.stem(filename)] else { return nil }
        let matches = entries.filter { abs($0.date.timeIntervalSince(date)) <= 2 }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }

    static func sameMoment(_ a: Date, _ b: Date) -> Bool {
        let difference = abs(a.timeIntervalSince(b))
        guard difference <= 14 * 3600 + 2 else { return false }
        let offHour = difference.truncatingRemainder(dividingBy: 3600)
        return offHour <= 2 || offHour >= 3600 - 2
    }

    public static func stem(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension.lowercased()
    }
}
