import CryptoKit
import Darwin
import Foundation
import Security

struct EncryptedHistory {
    // JSON can use six bytes for each escaped text byte. Leave room for metadata and the GCM box.
    private static let maximumCiphertextBytes = 241_000_000
    private static let stagingPrefix = ".encrypted-history-"
    private static let payloadsDirectoryName = "payloads"
    private static let payloadExtension = "encrypted"

    private let fileURL: URL
    private let payloadsDirectory: URL
    private let keyProvider: () -> SymmetricKey?

    init(fileURL: URL, keyProvider: @escaping () -> SymmetricKey? = HistoryKey.loadOrCreate) {
        self.fileURL = fileURL
        self.payloadsDirectory = fileURL.deletingLastPathComponent()
            .appendingPathComponent(Self.payloadsDirectoryName, isDirectory: true)
        self.keyProvider = keyProvider
    }

    func loadIndex() -> [ClipboardItem]? {
        guard fileURL.isFileURL else { return nil }
        removeAbandonedStaging(in: fileURL.deletingLastPathComponent())
        removeAbandonedStaging(in: payloadsDirectory)

        guard let plaintext = readAndDecrypt(at: fileURL) else {
            return errno == ENOENT && !FileManager.default.fileExists(atPath: fileURL.path) ? [] : nil
        }

        if let items = try? JSONDecoder().decode([ClipboardItem].self, from: plaintext) {
            return items
        }

        // Migrate legacy v1 inline-content snapshots lazily into per-item encrypted blobs.
        if let legacyItems = try? JSONDecoder().decode([LegacyClipboardItem].self, from: plaintext) {
            var migrated: [ClipboardItem] = []
            migrated.reserveCapacity(legacyItems.count)
            for legacy in legacyItems {
                let item = ClipboardItem(
                    id: legacy.id,
                    content: legacy.content,
                    date: legacy.date,
                    sourceBundleID: legacy.sourceBundleID,
                    isPinned: legacy.isPinned ?? false
                )
                if savePayload(legacy.content, for: item.id) {
                    migrated.append(item)
                }
            }
            return migrated
        }

        return nil
    }

    @discardableResult
    func saveIndex(_ items: [ClipboardItem]) -> Bool {
        guard fileURL.isFileURL else { return false }
        if items.isEmpty {
            prunePayloads(keeping: [])
            return unlink(fileURL.path) == 0 || errno == ENOENT
        }
        guard let key = keyProvider() else { return false }

        do {
            let json = try JSONEncoder().encode(items)
            guard let encrypted = try AES.GCM.seal(json, using: key).combined,
                  encrypted.count <= Self.maximumCiphertextBytes else { return false }
            let wrote = try replaceEncryptedFile(at: fileURL, with: encrypted)
            if wrote {
                prunePayloads(keeping: Set(items.map(\.id)))
            }
            return wrote
        } catch {
            return false
        }
    }

    @discardableResult
    func savePayload(_ content: ClipboardContent, for id: UUID) -> Bool {
        guard fileURL.isFileURL, let key = keyProvider() else { return false }
        do {
            let json = try JSONEncoder().encode(content)
            guard let encrypted = try AES.GCM.seal(json, using: key).combined,
                  encrypted.count <= Self.maximumCiphertextBytes else { return false }
            return try replaceEncryptedFile(at: payloadURL(for: id), with: encrypted)
        } catch {
            return false
        }
    }

    func loadPayload(for id: UUID) -> ClipboardContent? {
        guard fileURL.isFileURL else { return nil }
        guard let plaintext = readAndDecrypt(at: payloadURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(ClipboardContent.self, from: plaintext)
    }

    func deletePayload(for id: UUID) {
        guard fileURL.isFileURL else { return }
        _ = unlink(payloadURL(for: id).path)
    }

    func prunePayloads(keeping validIDs: Set<UUID>) {
        guard fileURL.isFileURL else { return }
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(at: payloadsDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(Self.stagingPrefix) { continue }
            guard child.pathExtension == Self.payloadExtension else { continue }
            let stem = child.deletingPathExtension().lastPathComponent
            guard let uuid = UUID(uuidString: stem), validIDs.contains(uuid) else {
                _ = unlink(child.path)
                continue
            }
        }
        if validIDs.isEmpty {
            try? fileManager.removeItem(at: payloadsDirectory)
        }
    }

    func payloadFileURL(for id: UUID) -> URL {
        payloadURL(for: id)
    }

    private func payloadURL(for id: UUID) -> URL {
        payloadsDirectory.appendingPathComponent("\(id.uuidString).\(Self.payloadExtension)")
    }

    private func readAndDecrypt(at url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= Self.maximumCiphertextBytes,
              let key = keyProvider() else { return nil }

        do {
            let size = Int(info.st_size)
            guard let encrypted = try handle.read(upToCount: size + 1), encrypted.count == size else { return nil }
            let box = try AES.GCM.SealedBox(combined: encrypted)
            return try AES.GCM.open(box, using: key)
        } catch {
            return nil
        }
    }

    private func replaceEncryptedFile(at targetURL: URL, with encrypted: Data) throws -> Bool {
        let fileManager = FileManager.default
        let directory = targetURL.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(Self.stagingPrefix + UUID().uuidString,
                                                       isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Directory exclusion covers the snapshot throughout staging and atomic replacement.
        var backupDirectory = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try backupDirectory.setResourceValues(resources)
        backupDirectory.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
        guard try backupDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup == true else { return false }

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        let stagingDescriptor = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        defer {
            try? fileManager.removeItem(at: staging)
            if stagingDescriptor >= 0 { _ = close(stagingDescriptor) }
        }
        guard stagingDescriptor >= 0, flock(stagingDescriptor, LOCK_EX | LOCK_NB) == 0 else { return false }

        let stagedFile = staging.appendingPathComponent(targetURL.lastPathComponent)
        let descriptor = open(stagedFile.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fchmod(descriptor, 0o600) == 0 else { return false }

        try handle.write(contentsOf: encrypted)
        try handle.synchronize()
        try handle.close()
        guard rename(stagedFile.path, targetURL.path) == 0 else { return false }

        // The directory remains excluded even when the volume cannot mark an individual file.
        var installedFile = targetURL
        try? installedFile.setResourceValues(resources)
        return true
    }

    private func removeAbandonedStaging(in directory: URL) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for child in children where child.lastPathComponent.hasPrefix(Self.stagingPrefix) {
            let suffix = child.lastPathComponent.dropFirst(Self.stagingPrefix.count)
            guard UUID(uuidString: String(suffix)) != nil else { continue }
            let descriptor = open(child.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            defer { _ = close(descriptor) }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    private struct LegacyClipboardItem: Codable {
        let id: UUID
        let content: ClipboardContent
        let date: Date
        let sourceBundleID: String?
        let isPinned: Bool?
    }
}

enum HistoryKey {
    static func loadOrCreate() -> SymmetricKey? {
        var protectedAttributes = attributes(account: "data-protection-aes-gcm-v1")
        protectedAttributes[kSecUseDataProtectionKeychain as String] = true
        protectedAttributes[kSecAttrSynchronizable as String] = false
        let protectedKey = loadOrCreateItem(protectedAttributes, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) {
            SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        }
        if protectedKey.status == errSecSuccess {
            guard let data = protectedKey.data, data.count == 32 else { return nil }
            return SymmetricKey(data: data)
        }
        // Ad hoc signed builds lack a provisioned access group. Persist only a key
        // that the local Secure Enclave can unwrap in the file-based Keychain.
        guard protectedKey.status == errSecMissingEntitlement, SecureEnclave.isAvailable else { return nil }
        let wrappedKey = loadOrCreateItem(attributes(account: "secure-enclave-p256-hkdf-v1")) {
            let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            let peer = P256.KeyAgreement.PrivateKey().publicKey
            let material = EnclaveKey(wrappedPrivateKey: privateKey.dataRepresentation,
                                      peerPublicKey: peer.x963Representation)
            _ = try material.deriveKey()
            return try JSONEncoder().encode(material)
        }
        guard let data = wrappedKey.data,
              let material = try? JSONDecoder().decode(EnclaveKey.self, from: data) else { return nil }
        return try? material.deriveKey()
    }

    private static func attributes(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.kastor.clipboard.history",
            kSecAttrAccount as String: account
        ]
    }

    private static func loadOrCreateItem(_ attributes: [String: Any], accessibility: CFString? = nil,
                                         generate: () throws -> Data) -> (status: OSStatus, data: Data?) {
        var query = attributes
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecItemNotFound else { return (status, result as? Data) }
        guard let data = try? generate() else { return (errSecNotAvailable, nil) }

        var item = attributes
        item[kSecValueData as String] = data
        if let accessibility { item[kSecAttrAccessible as String] = accessibility }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecDuplicateItem else { return (addStatus, addStatus == errSecSuccess ? data : nil) }

        // Another caller may have created the key after the first lookup.
        result = nil
        let rereadStatus = SecItemCopyMatching(query as CFDictionary, &result)
        return (rereadStatus, result as? Data)
    }

    private struct EnclaveKey: Codable {
        let wrappedPrivateKey: Data
        let peerPublicKey: Data

        func deriveKey() throws -> SymmetricKey {
            let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: wrappedPrivateKey)
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey)
            return try privateKey.sharedSecretFromKeyAgreement(with: peer).hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: Data(), sharedInfo: Data("com.kastor.clipboard.history/aes-gcm/v1".utf8),
                outputByteCount: 32
            )
        }
    }
}
