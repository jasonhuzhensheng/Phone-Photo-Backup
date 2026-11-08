import Foundation
import Testing
@testable import BackupCore

@Suite struct DirectImportTests {
    @Test func timeIndexedLibraryMatchesLikeTheFullIndexAndReadsFewNames() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 10,000 library items one minute apart, plus two that matter.
        var dates: [Date?] = (0..<10_000).map { base.addingTimeInterval(Double($0) * 60 + 30) }
        var names = (0..<10_000).map { "IMG_\($0).HEIC" }
        dates += [base.addingTimeInterval(1), base.addingTimeInterval(7200 + 5000)]
        names += ["IMG_7000.HEIC", "IMG_7001.MOV"]
        dates.append(nil); names.append("NODATE.JPG")
        let ids = names.indices.map { "id-\($0)" }
        let library = TimeIndexedLibrary(dates: dates, ids: ids) { names[$0] }

        #expect(library.contains(filename: "IMG_7000.JPG", date: base))               // same stem, 1 s apart
        #expect(library.contains(filename: "img_7001.heic", date: base.addingTimeInterval(5000 + 1))) // 2 h shift
        #expect(!library.contains(filename: "IMG_7001.HEIC", date: base.addingTimeInterval(5000 + 1800)))
        #expect(!library.contains(filename: "IMG_7000.HEIC", date: base.addingTimeInterval(4)))
        #expect(!library.contains(filename: "NODATE.JPG", date: nil))
        #expect(library.uniqueMatch(filename: "IMG_7000.HEIC", date: base) == "id-10000")
        #expect(library.uniqueMatch(filename: "IMG_7001.MOV", date: base.addingTimeInterval(5000)) == nil) // no shift allowed
        #expect(library.namesRead < 50)

        library.add(filename: "NEW_1.HEIC", date: base.addingTimeInterval(99))
        #expect(library.contains(filename: "NEW_1.JPG", date: base.addingTimeInterval(100)))
    }

    @Test func phoneFilesArePairedIntoLivePhotosAndRecorded() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            PhoneItem(relativePath: "DCIM/100APPLE/IMG_0002.HEIC", size: 10, date: day.addingTimeInterval(60)),
            PhoneItem(relativePath: "DCIM/100APPLE/IMG_0002.MOV", size: 20, date: day.addingTimeInterval(60)),
            PhoneItem(relativePath: "DCIM/100APPLE/IMG_0001.MOV", size: 30, date: day),
            PhoneItem(relativePath: "DCIM/100APPLE/IMG_0002.AAE", size: 1, date: day),
            PhoneItem(relativePath: "DCIM/101APPLE/IMG_0002.JPG", size: 5, date: day.addingTimeInterval(120)),
        ]
        let grouped = PhotosImport.phoneItems(items)
        #expect(grouped.map(\.primary.filename) == ["IMG_0001.MOV", "IMG_0002.HEIC", "IMG_0002.JPG"])
        #expect(grouped[0].photo == nil && grouped[0].video?.size == 30)
        #expect(grouped[1].video?.filename == "IMG_0002.MOV")
        #expect(grouped[2].video == nil)

        var ledger = ImportLedger()
        #expect(!ledger.handled(grouped[1], deviceID: "A"))
        ledger.recordPhone(grouped[1], deviceID: "A", sha256: ["DCIM/100APPLE/IMG_0002.HEIC": "abc"])
        #expect(ledger.handled(grouped[1], deviceID: "A"))
        #expect(!ledger.handled(grouped[1], deviceID: "B"))
        #expect(ledger.phoneFiles?["A|DCIM/100APPLE/IMG_0002.MOV|20"] == "in-photos")

        // Older records without phone entries still load, and the new field round-trips.
        let old = Data(#"{"schema_version":1,"files":{}}"#.utf8)
        #expect(try JSONDecoder().decode(ImportLedger.self, from: old).phoneFiles == nil)
        let again = try JSONDecoder().decode(ImportLedger.self, from: JSONEncoder().encode(ledger))
        #expect(again.handled(grouped[1], deviceID: "A"))
    }

    @Test func itemsChosenInTheReviewAreLeftOutWholeAndRemembered() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let grouped = PhotosImport.phoneItems([
            PhoneItem(relativePath: "DCIM/100APPLE/IMG_0001.MOV", size: 900, date: day),
            PhoneItem(relativePath: "DCIM/100APPLE/IMG_0002.HEIC", size: 10, date: day.addingTimeInterval(60)),
            PhoneItem(relativePath: "DCIM/100APPLE/IMG_0002.MOV", size: 20, date: day.addingTimeInterval(60)),
            PhoneItem(relativePath: "DCIM/100APPLE/IMG_0003.JPG", size: 5, date: day.addingTimeInterval(120)),
        ])
        // Selecting only the video half of a Live Photo leaves the whole Live Photo out.
        let split = PhotosImport.split(grouped, excluding: ["DCIM/100APPLE/IMG_0001.MOV", "DCIM/100APPLE/IMG_0002.MOV"])
        #expect(split.kept.map(\.primary.filename) == ["IMG_0003.JPG"])
        #expect(split.excluded.map(\.primary.filename) == ["IMG_0001.MOV", "IMG_0002.HEIC"])

        var ledger = ImportLedger()
        ledger.recordPhone(split.excluded[0], deviceID: "A", as: ImportLedger.skippedInReview)
        ledger.recordPhone(split.excluded[1], deviceID: "A", as: ImportLedger.deletedInReview)
        #expect(split.excluded.allSatisfy { ledger.handled($0, deviceID: "A") })
        #expect(ledger.phoneFiles?["A|DCIM/100APPLE/IMG_0002.HEIC|10"] == "deleted")
        #expect(!ledger.handled(split.kept[0], deviceID: "A"))
    }
}
