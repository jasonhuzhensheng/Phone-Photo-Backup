import Foundation

/// A video file somewhere under the backup location.
public struct BackupVideo: Sendable, Hashable, Identifiable {
    public let url: URL
    /// Path relative to the scanned folder, with `/` separators.
    public let relativePath: String
    public let size: Int64
    public let date: Date?
    /// The video half of a Live Photo (a `.mov` next to a photo with the same name).
    public let isLivePhotoVideo: Bool

    public var id: String { relativePath }
    public var filename: String { (relativePath as NSString).lastPathComponent }
    /// The folder the video is in, relative to the scanned folder ("" for the top level).
    public var folder: String { (relativePath as NSString).deletingLastPathComponent }

    public init(url: URL, relativePath: String, size: Int64, date: Date?, isLivePhotoVideo: Bool = false) {
        self.url = url
        self.relativePath = relativePath
        self.size = size
        self.date = date
        self.isLivePhotoVideo = isLivePhotoVideo
    }
}

/// A folder in the tree of backup videos, with the total size of the videos under it.
public struct VideoFolder: Sendable, Hashable, Identifiable {
    /// Path relative to the scanned folder ("" for the top level).
    public let path: String
    public let name: String
    public let bytes: Int64
    public let count: Int
    /// Subfolders that contain videos, largest first; nil when there are none (for outline views).
    public let children: [VideoFolder]?

    public var id: String { path }
}

/// Lists the videos in the backup location so the user can find and remove the big ones.
public enum BackupVideos {
    /// Every video under `root`, skipping hidden files and folders (manifests, the staging area).
    /// Symbolic links are not followed.
    public static func scan(_ root: URL, isCancelled: () -> Bool = { false }) throws -> [BackupVideo] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .creationDateKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { throw CocoaError(.fileReadNoSuchFile) }

        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        var videos: [(url: URL, relative: String, size: Int64, date: Date?)] = []
        var photoStems: Set<String> = []   // "<folder>/<stem>" lowercased, for Live Photo pairs
        for case let url as URL in enumerator {
            if isCancelled() { throw CancellationError() }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            let ext = url.pathExtension.lowercased()
            if PhotosImport.videoExtensions.contains(ext) {
                videos.append((url, relative, Int64(values.fileSize ?? 0),
                               values.creationDate ?? values.contentModificationDate))
            } else if PhotosImport.imageExtensions.contains(ext) {
                photoStems.insert(stemKey(relative))
            }
        }
        return videos.map {
            BackupVideo(url: $0.url, relativePath: $0.relative, size: $0.size, date: $0.date,
                        isLivePhotoVideo: photoStems.contains(stemKey($0.relative)))
        }
    }

    /// The folders that contain `videos`, as a tree under one root node.
    public static func folderTree(_ videos: [BackupVideo], rootName: String) -> VideoFolder {
        final class Node {
            var bytes: Int64 = 0
            var count = 0
            var children: [String: Node] = [:]
        }
        let root = Node()
        for video in videos {
            var node = root
            node.bytes += video.size
            node.count += 1
            for part in video.folder.split(separator: "/") where !part.isEmpty {
                let next = node.children[String(part)] ?? Node()
                node.children[String(part)] = next
                node = next
                node.bytes += video.size
                node.count += 1
            }
        }
        func build(_ node: Node, path: String, name: String) -> VideoFolder {
            let children = node.children
                .map { build($0.value, path: path.isEmpty ? $0.key : path + "/" + $0.key, name: $0.key) }
                .sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
            return VideoFolder(path: path, name: name, bytes: node.bytes, count: node.count,
                               children: children.isEmpty ? nil : children)
        }
        return build(root, path: "", name: rootName)
    }

    /// The videos in `folder` and its subfolders ("" for all of them).
    public static func videos(_ videos: [BackupVideo], in folder: String) -> [BackupVideo] {
        guard !folder.isEmpty else { return videos }
        let prefix = folder + "/"
        return videos.filter { $0.relativePath.hasPrefix(prefix) }
    }

    private static func stemKey(_ relative: String) -> String {
        (relative as NSString).deletingPathExtension.lowercased()
    }
}
