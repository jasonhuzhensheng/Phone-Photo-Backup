import Foundation

/// On-disk manifest. The JSON layout matches the original Python version (schema 1),
/// so backups made by either version can be continued by the other.
struct Manifest: Codable {
    var schemaVersion: Int
    var sourceName: String
    var updatedAt: String?
    var files: [String: [Version]]

    struct Version: Codable {
        var sha256: String
        var sizeBytes: Int64
        var backupPath: String
        var firstSeen: String
        var lastSeen: String

        enum CodingKeys: String, CodingKey {
            case sha256
            case sizeBytes = "size_bytes"
            case backupPath = "backup_path"
            case firstSeen = "first_seen"
            case lastSeen = "last_seen"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sourceName = "source_name"
        case updatedAt = "updated_at"
        case files
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sourceName, forKey: .sourceName)
        try container.encode(updatedAt, forKey: .updatedAt) // explicit null, like Python
        try container.encode(files, forKey: .files)
    }

    static func timestamp() -> String {
        Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Adds a version for `relativePath`, or refreshes it when the same bytes were seen before.
    mutating func record(_ relativePath: String, sha256: String, size: Int64, backupPath: String) {
        let now = Self.timestamp()
        var versions = files[relativePath] ?? []
        if let index = versions.firstIndex(where: { $0.sha256 == sha256 }) {
            versions[index].lastSeen = now
            versions[index].backupPath = backupPath
        } else {
            versions.append(.init(sha256: sha256, sizeBytes: size, backupPath: backupPath, firstSeen: now, lastSeen: now))
        }
        files[relativePath] = versions
    }

    /// SHA-256 → stored path (relative to the backup folder) for every version, so a file whose
    /// source path changed is recognised instead of being stored a second time.
    func storedPathsByDigest() -> [String: String] {
        var map: [String: String] = [:]
        for versions in files.values {
            for version in versions where map[version.sha256] == nil { map[version.sha256] = version.backupPath }
        }
        return map
    }

    /// Marks the newest version of `relativePath` as seen again without re-reading it.
    mutating func touch(_ relativePath: String, version index: Int) {
        files[relativePath]?[index].lastSeen = Self.timestamp()
    }

    static func load(from path: String, sourceName: String) throws -> Manifest {
        guard FileManager.default.fileExists(atPath: path) else {
            return Manifest(schemaVersion: BackupEngine.schemaVersion, sourceName: sourceName, updatedAt: nil, files: [:])
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BackupError(.manifestUnreadable)
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == BackupEngine.schemaVersion,
              manifest.sourceName == sourceName
        else { throw BackupError(.manifestMismatch) }
        return manifest
    }

    func write(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        let directory = (path as NSString).deletingLastPathComponent
        let temporary = (directory as NSString)
            .appendingPathComponent(".photo-backup-manifest-\(UUID().uuidString.lowercased()).tmp")
        do {
            let handle = try FS.createExclusive(temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary, path) == 0 else { throw FS.posixError(path) }
        } catch {
            unlink(temporary)
            throw error
        }
    }
}
