import CryptoKit
import Foundation
import XCTest

final class HistoryStoreTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testAddsNewestFirstAndPreservesCopiedText() {
        var store = HistoryStore(fileURL: nil)
        let start = Date()
        XCTAssertTrue(store.add("first"))
        XCTAssertTrue(store.add(" second\n", sourceBundleID: "com.example.editor"))

        XCTAssertEqual(store.entries.map(\.text), [" second\n", "first"])
        XCTAssertEqual(store.entries.first?.sourceBundleID, "com.example.editor")
        XCTAssertNil(store.entries.last?.sourceBundleID)
        XCTAssertGreaterThanOrEqual(store.entries[0].date, start)
    }

    func testDuplicateMovesToTopAsAFreshEntryAndPreservesPin() {
        var store = HistoryStore(fileURL: nil)
        store.add("repeat", sourceBundleID: "com.example.first")
        let original = store.entries[0]
        XCTAssertTrue(store.togglePin(original.id))
        store.add("other")

        XCTAssertTrue(store.add("repeat", sourceBundleID: "com.example.second"))
        XCTAssertEqual(store.entries.map(\.text), ["repeat", "other"])
        XCTAssertNotEqual(store.entries.first?.id, original.id)
        XCTAssertEqual(store.entries.first?.isPinned, true)
        XCTAssertEqual(store.entries.first?.sourceBundleID, "com.example.second")
    }

    func testRejectsEmptyAndWhitespaceOnlyText() {
        var store = HistoryStore(fileURL: nil)
        store.add("keep")
        let original = store.entries

        XCTAssertFalse(store.add(""))
        XCTAssertFalse(store.add(" \t\r\n\u{00a0}"))
        XCTAssertEqual(store.entries, original)
    }

    func testLengthLimitCountsCharacters() {
        var store = HistoryStore(fileURL: nil)
        let maximum = String(repeating: "👩🏽‍💻", count: 100_000)

        XCTAssertTrue(store.add(maximum))
        XCTAssertFalse(store.add(maximum + "a"))
        XCTAssertEqual(store.loadContent(for: store.entries[0].id), .text(maximum))
    }

    func testDefaultLimitKeepsNewestHundredItems() {
        var store = HistoryStore(fileURL: nil)
        for index in 0...100 {
            store.add("item \(index)")
        }

        XCTAssertEqual(store.entries.map(\.text), (1...100).reversed().map { "item \($0)" })
    }

    func testConfiguredLimitAndLimitChangesTrimOldestUnpinnedWhilePreservingPinned() {
        var store = HistoryStore(fileURL: nil, limit: 2)
        store.add("pinned item")
        store.togglePin(store.entries[0].id)
        store.add("first")
        store.add("second")
        store.add("third")
        XCTAssertEqual(store.entries.map(\.text), ["pinned item", "third", "second"])

        store.setLimit(1)
        XCTAssertEqual(store.entries.map(\.text), ["pinned item", "third"])
        store.setLimit(3)
        store.add("fourth")
        XCTAssertEqual(store.entries.map(\.text), ["pinned item", "fourth", "third"])

        store.setLimit(0)
        XCTAssertEqual(store.entries.map(\.text), ["pinned item"])
        XCTAssertFalse(store.add("fifth"))
    }

    func testSearchMatchesCaseInsensitivelyIncludingTruncatedDiskPayloads() throws {
        let fileURL = try temporaryHistoryURL()
        var store = diskStore(fileURL)
        store.add("start Alpha")
        store.add("beta")
        let longText = String(repeating: "x", count: 1_500) + " HiddenNeedle"
        store.add(longText)

        XCTAssertEqual(store.inMemoryPayloadCount, 0)
        XCTAssertEqual(store.search("alpha").map(\.text), ["start Alpha"])
        XCTAssertEqual(store.search("hiddenneedle").count, 1)
        XCTAssertEqual(store.inMemoryPayloadCount, 0)
        XCTAssertEqual(store.search(""), store.entries)
        XCTAssertTrue(store.search("missing").isEmpty)
    }

    func testSecurityModeGatesSensitiveTokensAndFileURLs() {
        var store = HistoryStore(fileURL: nil)
        XCTAssertEqual(store.securityMode, .sensitive)

        let token = "github_pat_" + String(repeating: "a_", count: 25)
        let fileText = "file:///Users/example/secret.txt"
        XCTAssertFalse(store.add(token))
        XCTAssertFalse(store.add(fileText))
        XCTAssertTrue(store.entries.isEmpty)

        store.setSecurityMode(.normal)
        XCTAssertTrue(store.add(token))
        XCTAssertTrue(store.add(fileText))
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.loadContent(for: store.entries[0].id), .text(fileText))
        XCTAssertEqual(store.loadContent(for: store.entries[1].id), .text(token))
    }

    func testAutoDelete24HoursDefaultsOffAndExpiresUnpinnedOnlyWhenEnabled() throws {
        let start = Date()
        let fileURL = try temporaryHistoryURL()
        var store = diskStore(fileURL, now: start)
        XCTAssertFalse(store.autoDelete24Hours)

        store.add("pinned old", now: start)
        store.togglePin(store.entries[0].id)
        store.add("unpinned old", now: start.addingTimeInterval(1))
        store.add("unpinned newer", now: start.addingTimeInterval(3600))
        store.save()

        let after24h = start.addingTimeInterval(HistoryStore.retention + 10)
        XCTAssertFalse(store.expire(now: after24h))
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(diskStore(fileURL, autoDelete24Hours: false, now: after24h).entries.count, 3)

        XCTAssertTrue(store.setAutoDelete24Hours(true, now: after24h))
        XCTAssertEqual(store.entries.map(\.text), ["pinned old", "unpinned newer"])
        store.save()

        let afterAllUnpinned = start.addingTimeInterval(HistoryStore.retention + 4000)
        let reloaded = diskStore(fileURL, autoDelete24Hours: true, now: afterAllUnpinned)
        XCTAssertEqual(reloaded.entries.map(\.text), ["pinned old"])
    }

    func testRangeDeletionsPreservePinnedAndNonMatchingItems() throws {
        let fileURL = try temporaryHistoryURL()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15, minute: 0))!
        let todayDate = calendar.date(byAdding: .hour, value: -2, to: now)!
        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now)!
        let threeDaysAgoDate = calendar.date(byAdding: .day, value: -3, to: now)!
        let twoWeeksAgoDate = calendar.date(byAdding: .day, value: -14, to: now)!

        var store = diskStore(fileURL, now: now)
        store.add("pinned today", now: todayDate)
        store.togglePin(store.entries[0].id)
        store.add("today note", now: todayDate)
        store.add("yesterday note", now: yesterdayDate)
        store.add("week note", now: threeDaysAgoDate)
        store.add("ancient note", now: twoWeeksAgoDate)
        store.save()

        XCTAssertEqual(store.count(matching: .today, now: now, calendar: calendar), 1)
        XCTAssertEqual(store.count(matching: .yesterday, now: now, calendar: calendar), 1)
        XCTAssertEqual(store.count(matching: .lastWeek, now: now, calendar: calendar), 3)
        XCTAssertEqual(store.count(matching: .allTime, now: now, calendar: calendar), 4)

        XCTAssertEqual(store.delete(range: .today, now: now, calendar: calendar), 1)
        XCTAssertEqual(Set(store.entries.compactMap(\.text)), ["pinned today", "yesterday note", "week note", "ancient note"])

        XCTAssertEqual(store.delete(range: .yesterday, now: now, calendar: calendar), 1)
        XCTAssertEqual(Set(store.entries.compactMap(\.text)), ["pinned today", "week note", "ancient note"])

        XCTAssertEqual(store.delete(range: .lastWeek, now: now, calendar: calendar), 1)
        XCTAssertEqual(Set(store.entries.compactMap(\.text)), ["pinned today", "ancient note"])

        XCTAssertEqual(store.delete(range: .allTime, now: now, calendar: calendar), 1)
        XCTAssertEqual(store.entries.map(\.text), ["pinned today"])

        // Reload from disk to verify persistence and encrypted storage survived range deletion.
        let reloaded = diskStore(fileURL, now: now)
        XCTAssertEqual(reloaded.entries.map(\.text), ["pinned today"])
    }

    func testLowRAMPayloadStorageDoesNotHoldFullPayloadsInMemory() throws {
        let fileURL = try temporaryHistoryURL()
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="))
        let hugeText = String(repeating: "A", count: 80_000)

        var store = diskStore(fileURL)
        XCTAssertTrue(store.add(.image(image)))
        XCTAssertTrue(store.add(hugeText))
        store.save()

        XCTAssertEqual(store.inMemoryPayloadCount, 0)
        XCTAssertEqual(store.entries[0].previewText?.count, 240)
        XCTAssertEqual(store.entries[1].kind, .image)
        XCTAssertNil(store.entries[1].previewText)
        XCTAssertEqual(store.loadContent(for: store.entries[0].id), .text(hugeText))
        XCTAssertEqual(store.loadContent(for: store.entries[1].id), .image(image))
        XCTAssertEqual(store.inMemoryPayloadCount, 0)

        let ciphertext = try Data(contentsOf: fileURL)
        XCTAssertNil(ciphertext.range(of: Data(hugeText.utf8)))
        XCTAssertNil(ciphertext.range(of: image))
    }

    func testPinningUnpinningMovingAndRemovingItems() throws {
        let fileURL = try temporaryHistoryURL()
        var store = diskStore(fileURL)
        store.add("first")
        let firstID = store.entries[0].id
        store.add("second")
        let secondID = store.entries[0].id

        XCTAssertTrue(store.togglePin(firstID))
        XCTAssertEqual(store.entries.map(\.text), ["first", "second"])
        XCTAssertFalse(store.togglePin(firstID))
        XCTAssertEqual(store.entries.map(\.text), ["first", "second"])

        store.moveToTop(secondID)
        XCTAssertEqual(store.entries.map(\.text), ["second", "first"])
        store.moveToTop(firstID)
        XCTAssertEqual(store.entries.map(\.text), ["first", "second"])
        store.save()

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        store.remove(firstID)
        XCTAssertEqual(diskStore(fileURL).entries.count, 2)
        store.save()
        XCTAssertEqual(diskStore(fileURL).entries.map(\.text), ["second"])
        XCTAssertEqual(try permissions(at: fileURL), 0o600)
        store.remove(secondID)
        store.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testClearDeletesSavedHistoryImmediately() throws {
        let fileURL = try temporaryHistoryURL()
        var store = diskStore(fileURL)
        store.add("saved")
        store.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testMissingAndCorruptHistoryLoadEmpty() throws {
        let fileURL = try temporaryHistoryURL()
        XCTAssertTrue(diskStore(fileURL).entries.isEmpty)

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{incomplete".utf8).write(to: fileURL)
        XCTAssertTrue(diskStore(fileURL).entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testMissingKeyFallsBackToMemoryWithoutWritingPlaintext() throws {
        let fileURL = try temporaryHistoryURL()
        var store = HistoryStore(fileURL: fileURL, keyProvider: { nil })
        XCTAssertTrue(store.add("keep in memory"))
        store.save()
        XCTAssertEqual(store.entries.map(\.text), ["keep in memory"])
        XCTAssertEqual(store.inMemoryPayloadCount, 1)
        XCTAssertEqual(store.loadContent(for: store.entries[0].id), .text("keep in memory"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func diskStore(
        _ url: URL,
        limit: Int = 100,
        autoDelete24Hours: Bool = false,
        securityMode: SecurityMode = .sensitive,
        now: Date = Date()
    ) -> HistoryStore {
        HistoryStore(
            fileURL: url,
            limit: limit,
            autoDelete24Hours: autoDelete24Hours,
            securityMode: securityMode,
            now: now,
            keyProvider: { [key] in key }
        )
    }

    private func temporaryHistoryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("Kastor", isDirectory: true)
            .appendingPathComponent("history.encrypted")
    }

    private func permissions(at fileURL: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
    }
}
