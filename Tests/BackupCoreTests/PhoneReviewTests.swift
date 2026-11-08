import Foundation
import Testing
@testable import BackupCore

@Suite struct PhoneReviewTests {
    let mb: Int64 = 1 << 20

    @Test func largestVideosAreSortedAndFiltered() {
        let items = [
            PhoneItem(relativePath: "DCIM/IMG_1.MOV", size: 300 * mb, date: nil),
            PhoneItem(relativePath: "DCIM/IMG_2.MOV", size: 10 * mb, date: nil),   // too small
            PhoneItem(relativePath: "DCIM/IMG_3.HEIC", size: 900 * mb, date: nil), // not a video
            PhoneItem(relativePath: "DCIM/IMG_4.MP4", size: 1200 * mb, date: nil),
        ]
        #expect(PhoneReview.largestVideos(items).map(\.filename) == ["IMG_4.MP4", "IMG_1.MOV"])
    }

    @Test func onlySameSizeFilesAreHashed() async throws {
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        let items = [
            PhoneItem(relativePath: "DCIM/IMG_0001.JPG", size: 100, date: old.addingTimeInterval(60)),
            PhoneItem(relativePath: "DCIM/IMG_0002.JPG", size: 100, date: old),       // same bytes, older
            PhoneItem(relativePath: "DCIM/IMG_0003.JPG", size: 100, date: nil),       // same size, other bytes
            PhoneItem(relativePath: "DCIM/IMG_0004.JPG", size: 555, date: nil),       // unique size
            PhoneItem(relativePath: "DCIM/IMG_0004.AAE", size: 100, date: nil),       // not media
        ]
        let contents = ["DCIM/IMG_0001.JPG": "A", "DCIM/IMG_0002.JPG": "A", "DCIM/IMG_0003.JPG": "B"]
        let hashed = Counter()
        let groups = try await PhoneReview.findDuplicates(items) { item in
            hashed.increment()
            return contents[item.relativePath]!
        }
        #expect(hashed.value == 3)
        #expect(groups.count == 1)
        #expect(groups[0].keep.filename == "IMG_0002.JPG")
        #expect(groups[0].extras.map(\.filename) == ["IMG_0001.JPG"])
        #expect(groups[0].reclaimable == 100)
    }

    @Test func onlyVerifiedBackupsMayBeDeleted() async throws {
        let f = try DeviceFixture()
        let report = try await f.backup()
        let backedUp = PhoneItem(relativePath: "DCIM/100APPLE/IMG_0001.HEIC", size: Int64("simulated heic".utf8.count), date: nil)
        let wrongSize = PhoneItem(relativePath: "DCIM/100APPLE/IMG_0002.MOV", size: 1, date: nil)
        let unknown = PhoneItem(relativePath: "DCIM/100APPLE/IMG_9999.MOV", size: 5, date: nil)
        var result = PhoneReview.backedUp([backedUp, wrongSize, unknown], in: report.backupDirectory)
        #expect(result.safe == [backedUp])
        #expect(result.missing == [wrongSize, unknown])

        let hashes = PhoneReview.backupHashes(of: [backedUp, unknown], in: report.backupDirectory)
        #expect(hashes.count == 1)
        #expect(hashes[backedUp.relativePath]?.count == 64)

        let copy = try #require(PhoneReview.backupCopy(of: backedUp, in: report.backupDirectory))
        #expect(try Data(contentsOf: copy) == Data("simulated heic".utf8))
        #expect(PhoneReview.backupCopy(of: wrongSize, in: report.backupDirectory) == nil)

        // A backup copy that has gone missing is no longer a reason to allow deletion.
        try FileManager.default.removeItem(at: report.backupDirectory.appendingPathComponent(backedUp.relativePath))
        result = PhoneReview.backedUp([backedUp], in: report.backupDirectory)
        #expect(result.safe.isEmpty)
        #expect(PhoneReview.backupCopy(of: backedUp, in: report.backupDirectory) == nil)
    }
}
