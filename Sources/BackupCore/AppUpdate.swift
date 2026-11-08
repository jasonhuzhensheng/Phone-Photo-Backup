import Foundation

/// A dotted version number such as `2.9.0` (a leading `v` is ignored), compared part by part.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let x = index < a.parts.count ? a.parts[index] : 0
            let y = index < b.parts.count ? b.parts[index] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// The latest release on GitHub, as returned by `GET /repos/{owner}/{repo}/releases/latest`.
public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int64
        /// `sha256:<hex>`, filled in by GitHub for uploaded assets.
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// A newer version that can be installed.
public struct AppUpdateOffer: Sendable {
    public let version: AppVersion
    public let notes: String
    public let pageURL: URL
    public let downloadURL: URL
    public let size: Int64
    /// Lowercase hex SHA-256 of the zip; nil when the release does not give one (then the update
    /// is not installed automatically, only the release page is offered).
    public let sha256: String?
}

public enum AppUpdate {
    /// Release assets are named `Phone-Photo-Backup-<version>.zip` (made by `scripts/release.sh`).
    public static let assetPrefix = "Phone-Photo-Backup-"

    /// The offer when `release` is newer than `current` and carries the app zip; otherwise nil.
    public static func offer(current: AppVersion, release: GitHubRelease) -> AppUpdateOffer? {
        guard let version = AppVersion(release.tagName), current < version,
              let asset = release.assets.first(where: { $0.name.hasPrefix(assetPrefix) && $0.name.hasSuffix(".zip") })
        else { return nil }
        let notes = release.body ?? ""
        return AppUpdateOffer(version: version, notes: Self.notesWithoutChecksum(notes),
                              pageURL: release.htmlURL, downloadURL: asset.browserDownloadURL,
                              size: asset.size, sha256: sha256(from: asset.digest) ?? sha256(inNotes: notes))
    }

    static func sha256(from digest: String?) -> String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        return validHex(String(digest.dropFirst("sha256:".count)))
    }

    /// The `SHA-256: <hex>` line that `scripts/release.sh` writes into the release notes.
    static func sha256(inNotes notes: String) -> String? {
        for line in notes.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("SHA-256:") {
                return validHex(String(trimmed.dropFirst("SHA-256:".count)))
            }
        }
        return nil
    }

    private static func notesWithoutChecksum(_ notes: String) -> String {
        notes.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("SHA-256:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validHex(_ text: String) -> String? {
        let hex = text.trimmingCharacters(in: .whitespaces).lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case checksumMismatch
        case noApp
        case wrongApp(String)
        case wrongVersion(String)
        case badSignature
        case tool(String)

        public var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                String(localized: "The downloaded update is damaged (SHA-256 does not match). Nothing was changed.")
            case .noApp:
                String(localized: "The downloaded update does not contain the app. Nothing was changed.")
            case .wrongApp(let id):
                String(localized: "The downloaded update is a different app (\(id)). Nothing was changed.")
            case .wrongVersion(let version):
                String(localized: "The downloaded update has version \(version), not the one offered. Nothing was changed.")
            case .badSignature:
                String(localized: "The downloaded app's code signature is not valid. Nothing was changed.")
            case .tool(let message):
                message
            }
        }
    }

    /// Checks a downloaded zip and unpacks it into `directory`: the SHA-256 must match, and the
    /// zip must hold one app with the expected bundle identifier, version and a valid signature.
    /// Returns the unpacked app.
    public static func unpack(zip: URL, sha256 expected: String, into directory: URL,
                              bundleIdentifier: String, version: AppVersion) throws -> URL {
        guard try BackupEngine.sha256(of: zip.path) == expected.lowercased() else { throw Failure.checksumMismatch }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path])
        let apps = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first,
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        else { throw Failure.noApp }
        let id = info["CFBundleIdentifier"] as? String ?? "?"
        guard id == bundleIdentifier else { throw Failure.wrongApp(id) }
        let found = info["CFBundleShortVersionString"] as? String ?? "?"
        guard AppVersion(found) == version else { throw Failure.wrongVersion(found) }
        do {
            try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path])
        } catch {
            throw Failure.badSignature
        }
        // Downloads made by the app are not quarantined, but clear it in case.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// A shell script that waits for process `pid` to exit, swaps `newApp` into `target` (keeping
    /// the old app if the swap fails), runs `relaunch` and removes `workDirectory`.
    public static func installScript(pid: Int32, newApp: URL, target: URL, workDirectory: URL,
                                     relaunch: [String]) -> String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let old = workDirectory.appendingPathComponent("previous.app").path
        return """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        if mv \(quote(target.path)) \(quote(old)); then
          if ! mv \(quote(newApp.path)) \(quote(target.path)); then
            mv \(quote(old)) \(quote(target.path))
          fi
        fi
        \(relaunch.map(quote).joined(separator: " "))
        rm -rf \(quote(workDirectory.path))
        rm -f "$0"

        """
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.tool("\((tool as NSString).lastPathComponent): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}
