import Foundation

/// The Photos library, indexed by capture time only. File names are read (through `name`) just for
/// library items whose time matches what is being looked up, so building it stays fast even in a
/// library of 100,000 items, where reading every file name takes many minutes.
/// Matching rules are the same as `LibraryIndex`. Not thread-safe: use it from one task at a time.
public final class TimeIndexedLibrary: @unchecked Sendable {
    /// Reads the original file name of the library item at a position; called lazily, once each.
    public typealias NameLookup = (Int) -> String?

    private let dates: [Date?]
    private let ids: [String]
    private let name: NameLookup
    private var bySecond: [Int64: [Int]] = [:]
    private var stems: [Int: String] = [:]
    private var added = LibraryIndex()
    /// How many file names have been read so far (for tests and logging).
    public private(set) var namesRead = 0

    public init(dates: [Date?], ids: [String], name: @escaping NameLookup) {
        precondition(dates.count == ids.count)
        self.dates = dates
        self.ids = ids
        self.name = name
        for (position, date) in dates.enumerated() {
            if let date { bySecond[Self.second(date.timeIntervalSince1970), default: []].append(position) }
        }
    }

    public var count: Int { ids.count }

    /// Records an item added during this run, so a second copy of it is recognized.
    public func add(filename: String, date: Date?, id: String? = nil) {
        added.add(filename: filename, date: date, id: id)
    }

    /// Same rule as `LibraryIndex.contains`: same name stem, time within two seconds, allowing a
    /// whole-hour time-zone shift of up to 14 hours.
    public func contains(filename: String, date: Date?) -> Bool {
        guard let date else { return false }
        if added.contains(filename: filename, date: date) { return true }
        let stem = LibraryIndex.stem(filename)
        for hours in -14...14 {
            let time = date.timeIntervalSince1970 + Double(hours) * 3600
            if candidates(around: time).contains(where: { stemOf($0) == stem }) { return true }
        }
        return false
    }

    /// Same rule as `LibraryIndex.uniqueMatch`: one item with the same stem within two seconds.
    public func uniqueMatch(filename: String, date: Date?) -> String? {
        guard let date else { return nil }
        let stem = LibraryIndex.stem(filename)
        let matches = candidates(around: date.timeIntervalSince1970).filter { stemOf($0) == stem }
        return matches.count == 1 ? ids[matches[0]] : nil
    }

    private func candidates(around time: TimeInterval) -> [Int] {
        var found: [Int] = []
        for second in Self.second(time - 2)...Self.second(time + 2) {
            for position in bySecond[second] ?? [] {
                if let date = dates[position], abs(date.timeIntervalSince1970 - time) <= 2 { found.append(position) }
            }
        }
        return found
    }

    private func stemOf(_ position: Int) -> String {
        if let stem = stems[position] { return stem }
        namesRead += 1
        let stem = name(position).map(LibraryIndex.stem) ?? ""
        stems[position] = stem
        return stem
    }

    private static func second(_ time: TimeInterval) -> Int64 { Int64(time.rounded(.down)) }
}

/// What becomes one item in Photos when importing straight from a phone: a photo, a video, or a
/// Live Photo (a photo and a `.mov` with the same name in the same folder).
public struct PhoneImportItem: Sendable, Hashable {
    public let photo: PhoneItem?
    public let video: PhoneItem?

    public var primary: PhoneItem { photo ?? video! }
    public var files: [PhoneItem] { [photo, video].compactMap { $0 } }
    public var size: Int64 { files.reduce(0) { $0 + $1.size } }
}

extension PhotosImport {
    /// Groups the photos and videos on a phone into Photos items, oldest first. Same pairing rule
    /// as for backups; files that are not photos or videos (such as `.AAE`) are left out.
    public static func phoneItems(_ items: [PhoneItem]) -> [PhoneImportItem] {
        var groups: [String: [PhoneItem]] = [:]
        for item in items where isMedia(item.relativePath) {
            groups[(item.relativePath as NSString).deletingPathExtension.lowercased(), default: []].append(item)
        }
        var result: [PhoneImportItem] = []
        for group in groups.values {
            let photos = group.filter { imageExtensions.contains(($0.relativePath as NSString).pathExtension.lowercased()) }
            let movies = group.filter { ($0.relativePath as NSString).pathExtension.lowercased() == "mov" }
            if photos.count == 1, movies.count == 1 {
                result.append(PhoneImportItem(photo: photos[0], video: movies[0]))
                for item in group where item != photos[0] && item != movies[0] { result.append(single(item)) }
            } else {
                result += group.map(single)
            }
        }
        return result.sorted {
            switch ($0.primary.date, $1.primary.date) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.primary.relativePath < $1.primary.relativePath
            }
        }
    }

    /// Splits `items` into those to import and those with a file in `paths`. A Live Photo is left
    /// out whole when either of its files is in `paths`: deleting it in Photos removes both.
    public static func split(_ items: [PhoneImportItem], excluding paths: Set<String>)
        -> (kept: [PhoneImportItem], excluded: [PhoneImportItem]) {
        var kept: [PhoneImportItem] = []
        var excluded: [PhoneImportItem] = []
        for item in items {
            if item.files.contains(where: { paths.contains($0.relativePath) }) {
                excluded.append(item)
            } else {
                kept.append(item)
            }
        }
        return (kept, excluded)
    }

    private static func single(_ item: PhoneItem) -> PhoneImportItem {
        imageExtensions.contains((item.relativePath as NSString).pathExtension.lowercased())
            ? PhoneImportItem(photo: item, video: nil) : PhoneImportItem(photo: nil, video: item)
    }
}

extension ImportLedger {
    /// Key for a file on a phone: the device, its path there and its size.
    public static func phoneKey(deviceID: String, _ item: PhoneItem) -> String {
        "\(deviceID)|\(item.relativePath)|\(item.size)"
    }

    /// True when every file of `item` was handled by an earlier direct import (imported, found in
    /// Photos, or deleted), so it is not read from the phone again.
    public func handled(_ item: PhoneImportItem, deviceID: String) -> Bool {
        item.files.allSatisfy { phoneFiles?[Self.phoneKey(deviceID: deviceID, $0)] != nil }
    }

    /// Record value for phone files the user deleted in the review before a direct import.
    public static let deletedInReview = "deleted"
    /// Record value for phone files the user chose not to import (not found in Photos to delete).
    public static let skippedInReview = "skipped"

    /// Remembers the phone files of `item` with a fixed value, such as `deletedInReview`, so later
    /// direct imports leave them out.
    public mutating func recordPhone(_ item: PhoneImportItem, deviceID: String, as value: String) {
        var records = phoneFiles ?? [:]
        for file in item.files { records[Self.phoneKey(deviceID: deviceID, file)] = value }
        phoneFiles = records
    }

    /// Remembers the phone files of `item`. `sha256` is nil when the item was found in Photos
    /// without being read from the phone.
    public mutating func recordPhone(_ item: PhoneImportItem, deviceID: String, sha256: [String: String]) {
        var records = phoneFiles ?? [:]
        for file in item.files {
            records[Self.phoneKey(deviceID: deviceID, file)] = sha256[file.relativePath] ?? "in-photos"
        }
        phoneFiles = records
    }
}
