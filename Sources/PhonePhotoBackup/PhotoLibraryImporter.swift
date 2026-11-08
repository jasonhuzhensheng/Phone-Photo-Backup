@preconcurrency import AVFoundation
import BackupCore
import Foundation
import ImageIO
@preconcurrency import Photos

/// Adds backed-up files to the system Photos library with PhotoKit. With iCloud Photos turned on,
/// Photos uploads them and they appear on every device signed in to the same Apple ID.
enum PhotoLibraryImporter {
    enum ImportError: LocalizedError {
        case notAuthorized

        var errorDescription: String? {
            String(localized: "Phone Photo Backup is not allowed to use Photos. Allow it in System Settings > Privacy & Security > Photos, then try again.")
        }
    }

    /// Name of the album that collects everything this app imports.
    static var albumName: String { String(localized: "Imported from Old Phones") }

    static func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else { throw ImportError.notAuthorized }
    }

    /// Everything already in the library, indexed by capture time. Original file names are read
    /// later, only for items whose time matches something being imported: reading every name up
    /// front takes many minutes in a large library.
    static func libraryLookup() -> TimeIndexedLibrary {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let assets = PHAsset.fetchAssets(with: options)
        var dates: [Date?] = []
        var ids: [String] = []
        dates.reserveCapacity(assets.count)
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            dates.append(asset.creationDate)
            ids.append(asset.localIdentifier)
        }
        return TimeIndexedLibrary(dates: dates, ids: ids) { position in
            let resources = PHAssetResource.assetResources(for: assets.object(at: position))
            let primary = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
            return primary?.originalFilename
        }
    }

    /// For each item, the identifier of the one library item with the same file name stem and a
    /// capture time within two seconds (no time-zone shift), or nothing when there is none or more
    /// than one. Only the few items around each time are looked at, so this stays fast in a large
    /// library (reading the whole library index takes minutes there). Same rule as
    /// `LibraryIndex.uniqueMatch`.
    static func uniqueMatches(for items: [(path: String, filename: String, date: Date?)]) throws -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            try Task.checkCancellation()
            guard let date = item.date else { continue }
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                            date.addingTimeInterval(-2) as NSDate, date.addingTimeInterval(2) as NSDate)
            let stem = LibraryIndex.stem(item.filename)
            var found: [String] = []
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                let primary = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
                if let name = primary?.originalFilename, LibraryIndex.stem(name) == stem {
                    found.append(asset.localIdentifier)
                }
            }
            if found.count == 1 { result[item.path] = found[0] }
        }
        return result
    }

    /// Moves library items to Recently Deleted (recoverable for 30 days). With iCloud Photos on,
    /// the deletion syncs to the iPhone, where the items also go to Recently Deleted. macOS asks the
    /// user to confirm. Returns how many items were deleted.
    static func moveToRecentlyDeleted(_ identifiers: [String]) async throws -> Int {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { return 0 }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
        return assets.count
    }

    /// When the photo or video was taken, from its metadata; the file date if there is none.
    static func captureDate(of url: URL) async -> Date? {
        let ext = url.pathExtension.lowercased()
        if ["mov", "mp4", "m4v", "3gp"].contains(ext) {
            let asset = AVURLAsset(url: url)
            if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) {
                return date
            }
        } else if let date = exifDate(of: url) {
            return date
        }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func exifDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
                ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String
                ?? tiff?[kCGImagePropertyTIFFDateTime] as? String else { return nil }
        let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: text + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: text)
    }

    /// Adds one item (photo, video or Live Photo) and returns the new asset's local identifier.
    /// A Live Photo that Photos refuses to pair is added as a separate photo and video.
    static func add(_ item: ImportItem) async throws -> String? {
        do {
            return try await create(item)
        } catch where item.isLivePhoto {
            let photoID = try await create(ImportItem(photo: item.photo, video: nil))
            _ = try await create(ImportItem(photo: nil, video: item.video))
            return photoID
        }
    }

    private static func create(_ item: ImportItem) async throws -> String? {
        let album = try await importAlbum()
        let created = CreatedID()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            func add(_ type: PHAssetResourceType, _ file: ImportFile) {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = file.filename
                options.shouldMoveFile = false // the backup copy stays where it is
                request.addResource(with: type, fileURL: file.url, options: options)
            }
            if let photo = item.photo { add(.photo, photo) }
            if let video = item.video { add(item.photo == nil ? .video : .pairedVideo, video) }
            if let placeholder = request.placeholderForCreatedAsset {
                created.value = placeholder.localIdentifier
                if let album, let change = PHAssetCollectionChangeRequest(for: album) {
                    change.addAssets([placeholder] as NSArray)
                }
            }
        }
        return created.value
    }

    /// The album that collects imports; created on first use.
    private static func importAlbum() async throws -> PHAssetCollection? {
        let name = albumName
        if let album = findAlbum(name) { return album }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
        }
        return findAlbum(name)
    }

    private static func findAlbum(_ name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
    }
}

private final class CreatedID: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
