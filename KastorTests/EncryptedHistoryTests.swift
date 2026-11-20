import CryptoKit
import Darwin
import Foundation
import XCTest

final class EncryptedHistoryTests: XCTestCase {
    func testRoundTripIndexAndPayloadsStayPrivateAndExcludedFromBackup() throws {
        let fileURL = try temporaryHistoryURL()
        let key = SymmetricKey(size: .bits256)
        let history = EncryptedHistory(fileURL: fileURL, keyProvider: { key })
        let textContent = ClipboardContent.text("encrypted clipboard text")
        let imageContent = ClipboardContent.image(Data([137, 80, 78, 71, 13, 10, 26, 10]))
        let text = ClipboardItem(id: UUID(), content: textContent, date: Date(), sourceBundleID: "com.example.editor")
        let image = ClipboardItem(id: UUID(), content: imageContent, date: Date(), sourceBundleID: nil)

        XCTAssertTrue(history.savePayload(textContent, for: text.id))
        XCTAssertTrue(history.savePayload(imageContent, for: image.id))
        XCTAssertTrue(history.saveIndex([text, image]))

        XCTAssertEqual(history.loadIndex(), [text, image])
        XCTAssertEqual(history.loadPayload(for: text.id), textContent)
        XCTAssertEqual(history.loadPayload(for: image.id), imageContent)

        let firstCiphertext = try Data(contentsOf: fileURL)
        XCTAssertNil(firstCiphertext.range(of: Data("encrypted clipboard text".utf8)))
        let payloadCiphertext = try Data(contentsOf: history.payloadFileURL(for: text.id))
        XCTAssertNil(payloadCiphertext.range(of: Data("encrypted clipboard text".utf8)))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        XCTAssertTrue(history.saveIndex([text, image]))
        XCTAssertEqual(history.loadIndex(), [text, image])
        XCTAssertNotEqual(try Data(contentsOf: fileURL), firstCiphertext)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let payloadAttrs = try FileManager.default.attributesOfItem(atPath: history.payloadFileURL(for: text.id).path)
        XCTAssertEqual(payloadAttrs[.posixPermissions] as? Int, 0o600)

        let directory = fileURL.deletingLastPathComponent()
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testMissingFileAndClearDoNotRequireKeychainAccess() throws {
        let fileURL = try temporaryHistoryURL()
        let key = SymmetricKey(size: .bits256)
        let available = EncryptedHistory(fileURL: fileURL, keyProvider: { key })
        let unavailable = EncryptedHistory(fileURL: fileURL, keyProvider: {
            XCTFail("Missing history and clearing must skip the key provider")
            return nil
        })

        XCTAssertEqual(unavailable.loadIndex(), [])
        XCTAssertTrue(unavailable.saveIndex([]))
        let item = textItem("clear me")
        XCTAssertTrue(available.savePayload(.text("clear me"), for: item.id))
        XCTAssertTrue(available.saveIndex([item]))

        XCTAssertTrue(unavailable.saveIndex([]))
        XCTAssertEqual(unavailable.loadIndex(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: available.payloadFileURL(for: item.id).path))
    }

    func testUnavailableKeyPreservesPriorSnapshot() throws {
        let fileURL = try temporaryHistoryURL()
        let key = SymmetricKey(size: .bits256)
        let available = EncryptedHistory(fileURL: fileURL, keyProvider: { key })
        let unavailable = EncryptedHistory(fileURL: fileURL, keyProvider: { nil })
        let original = textItem("prior snapshot")

        XCTAssertFalse(unavailable.saveIndex([original]))
        XCTAssertEqual(unavailable.loadIndex(), [])
        XCTAssertTrue(available.savePayload(.text("prior snapshot"), for: original.id))
        XCTAssertTrue(available.saveIndex([original]))
        let ciphertext = try Data(contentsOf: fileURL)

        XCTAssertNil(unavailable.loadIndex())
        XCTAssertFalse(unavailable.saveIndex([textItem("new content")]))
        XCTAssertEqual(try Data(contentsOf: fileURL), ciphertext)
        XCTAssertEqual(available.loadIndex(), [original])
    }

    func testWrongKeyAndTamperingFailAuthentication() throws {
        let fileURL = try temporaryHistoryURL()
        let key = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)
        let history = EncryptedHistory(fileURL: fileURL, keyProvider: { key })
        let wrongHistory = EncryptedHistory(fileURL: fileURL, keyProvider: { wrongKey })
        let item = textItem("authenticated history")

        XCTAssertTrue(history.savePayload(.text("authenticated history"), for: item.id))
        XCTAssertTrue(history.saveIndex([item]))
        XCTAssertNil(wrongHistory.loadIndex())
        XCTAssertNil(wrongHistory.loadPayload(for: item.id))

        var ciphertext = try Data(contentsOf: fileURL)
        ciphertext[ciphertext.index(before: ciphertext.endIndex)] ^= 1
        try ciphertext.write(to: fileURL)
        XCTAssertNil(history.loadIndex())

        var payloadCiphertext = try Data(contentsOf: history.payloadFileURL(for: item.id))
        payloadCiphertext[payloadCiphertext.index(before: payloadCiphertext.endIndex)] ^= 1
        try payloadCiphertext.write(to: history.payloadFileURL(for: item.id))
        XCTAssertNil(history.loadPayload(for: item.id))
    }

    func testOversizedCiphertextIsRejectedBeforeKeyLookup() throws {
        let fileURL = try temporaryHistoryURL()
        try Data().write(to: fileURL)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 242_000_000)
        try handle.close()
        let history = EncryptedHistory(fileURL: fileURL, keyProvider: {
            XCTFail("Oversized snapshots must be rejected before key lookup")
            return nil
        })

        XCTAssertNil(history.loadIndex())
    }

    func testLoadRemovesAbandonedStagingAndSkipsLockedStaging() throws {
        let fileURL = try temporaryHistoryURL()
        let directory = fileURL.deletingLastPathComponent()
        let abandoned = directory.appendingPathComponent(".encrypted-history-\(UUID().uuidString)")
        let active = directory.appendingPathComponent(".encrypted-history-\(UUID().uuidString)")
        let legacy = directory.appendingPathComponent(".history-\(UUID().uuidString)")
        for stagedDirectory in [abandoned, active, legacy] {
            try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: false)
        }
        let descriptor = open(active.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let history = EncryptedHistory(fileURL: fileURL, keyProvider: { nil })
        XCTAssertEqual(history.loadIndex(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testLegacyV1SnapshotMigratesToPerItemPayloads() throws {
        struct LegacyItem: Codable {
            let id: UUID
            let content: ClipboardContent
            let date: Date
            let sourceBundleID: String?
        }

        let fileURL = try temporaryHistoryURL()
        let key = SymmetricKey(size: .bits256)
        let id = UUID()
        let legacy = [LegacyItem(id: id, content: .text("legacy secret"), date: Date(), sourceBundleID: "com.example")]
        let json = try JSONEncoder().encode(legacy)
        let sealed = try XCTUnwrap(AES.GCM.seal(json, using: key).combined)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.write(to: fileURL)

        let history = EncryptedHistory(fileURL: fileURL, keyProvider: { key })
        let migrated = try XCTUnwrap(history.loadIndex())
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].id, id)
        XCTAssertEqual(history.loadPayload(for: id), .text("legacy secret"))
    }

    private func textItem(_ text: String) -> ClipboardItem {
        ClipboardItem(id: UUID(), content: .text(text), date: Date(), sourceBundleID: "com.example.editor")
    }

    private func temporaryHistoryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("history.encrypted")
    }
}
