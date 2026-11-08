import Foundation
import Testing
@testable import BackupCore

@Suite struct AppUpdateTests {
    @Test func versionsCompareNumerically() throws {
        let v = { (text: String) in try #require(AppVersion(text)) }
        #expect(try v("2.10.0") > v("2.9.0"))
        #expect(try v("v2.9") == v("2.9.0"))
        #expect(try v("2.9.1") > v("2.9"))
        #expect(AppVersion("2.x") == nil)
        #expect(AppVersion("") == nil)
        #expect(try v("v3.0.0").description == "3.0.0")
    }

    private func release(tag: String, digest: String?, body: String = "Notes") throws -> GitHubRelease {
        let digestField = digest.map { #","digest":"\#($0)""# } ?? ""
        let json = #"""
        {"tag_name":"\#(tag)","name":"Phone Photo Backup \#(tag)","body":\#(String(data: try JSONEncoder().encode(body), encoding: .utf8)!),
         "html_url":"https://github.com/o/r/releases/tag/\#(tag)",
         "assets":[{"name":"notes.txt","browser_download_url":"https://example.invalid/notes.txt","size":1},
                   {"name":"Phone-Photo-Backup-\#(tag.dropFirst()).zip","browser_download_url":"https://example.invalid/app.zip","size":1234\#(digestField)}]}
        """#
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    @Test func offerIsMadeOnlyForNewerReleasesWithTheAppZip() throws {
        let hex = String(repeating: "ab", count: 32)
        let current = try #require(AppVersion("2.8.0"))
        let offer = try #require(AppUpdate.offer(current: current, release: release(tag: "v2.9.0", digest: "sha256:\(hex)")))
        #expect(offer.version.description == "2.9.0")
        #expect(offer.sha256 == hex)
        #expect(offer.downloadURL.lastPathComponent == "app.zip")
        #expect(offer.size == 1234)
        #expect(AppUpdate.offer(current: current, release: try release(tag: "v2.8.0", digest: nil)) == nil)
        #expect(AppUpdate.offer(current: current, release: try release(tag: "v2.7.9", digest: nil)) == nil)

        // Without a GitHub digest, the checksum line in the notes is used and hidden from the notes.
        let fromNotes = try #require(AppUpdate.offer(current: current, release: release(
            tag: "v2.9.0", digest: nil, body: "Fixes.\n\nSHA-256: \(hex.uppercased())")))
        #expect(fromNotes.sha256 == hex)
        #expect(fromNotes.notes == "Fixes.")
        let none = try #require(AppUpdate.offer(current: current, release: release(tag: "v2.9.0", digest: nil)))
        #expect(none.sha256 == nil)
    }

    /// Builds a minimal signed app bundle (a copy of /usr/bin/true) and zips it like the release script.
    private func makeAppZip(in root: URL, id: String, version: String) throws -> URL {
        let app = root.appendingPathComponent("build-\(UUID().uuidString)/Phone Photo Backup.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("PhonePhotoBackup").path)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version,
                                  "CFBundleExecutable": "PhonePhotoBackup", "CFBundlePackageType": "APPL"]
        info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try AppUpdate.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.path])
        let zip = root.appendingPathComponent("Phone-Photo-Backup-\(version)-\(UUID().uuidString).zip")
        try AppUpdate.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        return zip
    }

    @Test func downloadedZipIsVerifiedBeforeUnpacking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppb-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = "io.github.example.PhonePhotoBackup"
        let version = try #require(AppVersion("2.9.0"))
        let zip = try makeAppZip(in: root, id: id, version: "2.9.0")
        let sha = try BackupEngine.sha256(of: zip.path)

        let app = try AppUpdate.unpack(zip: zip, sha256: sha, into: root.appendingPathComponent("ok"),
                                       bundleIdentifier: id, version: version)
        #expect(app.lastPathComponent == "Phone Photo Backup.app")

        #expect(throws: AppUpdate.Failure.checksumMismatch) {
            try AppUpdate.unpack(zip: zip, sha256: String(repeating: "0", count: 64), into: root.appendingPathComponent("a"),
                                 bundleIdentifier: id, version: version)
        }
        #expect(throws: AppUpdate.Failure.wrongApp(id)) {
            try AppUpdate.unpack(zip: zip, sha256: sha, into: root.appendingPathComponent("b"),
                                 bundleIdentifier: "other.app", version: version)
        }
        #expect(throws: AppUpdate.Failure.wrongVersion("2.9.0")) {
            try AppUpdate.unpack(zip: zip, sha256: sha, into: root.appendingPathComponent("c"),
                                 bundleIdentifier: id, version: try #require(AppVersion("3.0")))
        }

        // A bundle changed after signing is refused.
        let tamperedDir = root.appendingPathComponent("tampered-src")
        let source = try AppUpdate.unpack(zip: zip, sha256: sha, into: tamperedDir, bundleIdentifier: id, version: version)
        try Data("changed".utf8).write(to: source.appendingPathComponent("Contents/MacOS/PhonePhotoBackup"))
        let tamperedZip = root.appendingPathComponent("tampered.zip")
        try AppUpdate.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, tamperedZip.path])
        #expect(throws: AppUpdate.Failure.badSignature) {
            try AppUpdate.unpack(zip: tamperedZip, sha256: try BackupEngine.sha256(of: tamperedZip.path),
                                 into: root.appendingPathComponent("d"), bundleIdentifier: id, version: version)
        }
    }

    @Test func installScriptSwapsTheAppAndRelaunches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppb-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Applications/Phone Photo Backup.app")
        let work = root.appendingPathComponent("work it's")
        let newApp = work.appendingPathComponent("unpacked/Phone Photo Backup.app")
        for (app, marker) in [(target, "old"), (newApp, "new")] {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: app.appendingPathComponent("marker"))
        }
        let relaunched = root.appendingPathComponent("relaunched")
        // A process that has already exited, so the script does not wait.
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let script = AppUpdate.installScript(pid: finished.processIdentifier, newApp: newApp, target: target,
                                             workDirectory: work, relaunch: ["/usr/bin/touch", relaunched.path])
        let scriptURL = root.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try AppUpdate.run("/bin/sh", [scriptURL.path])

        #expect(try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: relaunched.path))
        #expect(!FileManager.default.fileExists(atPath: work.path))
        #expect(!FileManager.default.fileExists(atPath: scriptURL.path)) // the script removes itself
    }
}
