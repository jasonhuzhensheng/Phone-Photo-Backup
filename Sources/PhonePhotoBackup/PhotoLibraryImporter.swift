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

    /// File names and capture dates of everything already in the library.
    static func libraryIndex() -> LibraryIndex {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let assets = PHAsset.fetchAssets(with: options)
        var index = LibraryIndex()
        assets.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let primary = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
            if let name = primary?.originalFilename {
                index.add(filename: name, date: asset.creationDate)
            }
        }
        return index
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
