import Foundation
import Testing
@testable import BackupCore

@Suite struct BackupVideosTests {
    /// Writes `size` bytes of simulated content at `path` under `root`.
    private func write(_ root: URL, _ path: String, size: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: size).write(to: url)
    }

    @Test func videosAreFoundInSubfoldersWithLivePhotosMarked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppb-videos-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "iPhone_backup/DCIM/100APPLE/IMG_0001.MOV", size: 300)
        try write(root, "iPhone_backup/DCIM/100APPLE/IMG_0002.HEIC", size: 10)
        try write(root, "iPhone_backup/DCIM/100APPLE/IMG_0002.MOV", size: 20)     // Live Photo
        try write(root, "iPhone_backup/DCIM/101APPLE/IMG_0003.mp4", size: 100)
        try write(root, "Old_backup/clip.m4v", size: 50)
        try write(root, "Old_backup/notes.txt", size: 999)
        try write(root, "iPhone_backup/.phone-photo-backup-staging/IMG_9.MOV", size: 999)
        try write(root, "top.mov", size: 5)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.mov"),
                                                   withDestinationURL: root.appendingPathComponent("top.mov"))

        let videos = try BackupVideos.scan(root).sorted { $0.relativePath < $1.relativePath }
        #expect(videos.map(\.relativePath) == [
            "Old_backup/clip.m4v",
            "iPhone_backup/DCIM/100APPLE/IMG_0001.MOV",
            "iPhone_backup/DCIM/100APPLE/IMG_0002.MOV",
            "iPhone_backup/DCIM/101APPLE/IMG_0003.mp4",
            "top.mov",
        ])
        #expect(videos.filter(\.isLivePhotoVideo).map(\.filename) == ["IMG_0002.MOV"])
        #expect(videos.map(\.size) == [50, 300, 20, 100, 5])
        #expect(videos[1].folder == "iPhone_backup/DCIM/100APPLE")

        let tree = BackupVideos.folderTree(videos, rootName: "Backups")
        #expect(tree.bytes == 475 && tree.count == 5)
        #expect(tree.children?.map(\.name) == ["iPhone_backup", "Old_backup"])
        let dcim = try #require(tree.children?.first?.children?.first)
        #expect(dcim.path == "iPhone_backup/DCIM")
        #expect(dcim.children?.map(\.name) == ["100APPLE", "101APPLE"])
        #expect(dcim.children?.first?.children == nil)

        #expect(BackupVideos.videos(videos, in: "iPhone_backup/DCIM").count == 3)
        #expect(BackupVideos.videos(videos, in: "iPhone_backup/DCIM/101APPLE").map(\.filename) == ["IMG_0003.mp4"])
        #expect(BackupVideos.videos(videos, in: "").count == 5)
        // A folder name that is only a prefix of another does not match it.
        #expect(BackupVideos.videos(videos, in: "iPhone").isEmpty)
    }
}
