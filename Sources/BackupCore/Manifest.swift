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
