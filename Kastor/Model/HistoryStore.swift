import CryptoKit
import Foundation

enum ClipboardItemKind: String, Codable, Equatable {
    case text
    case image
}

enum DeleteRange: String, CaseIterable, Identifiable {
    case today
    case yesterday
    case lastWeek
    case allTime

    var id: String { rawValue }
}

enum ClipboardContent: Codable, Equatable {
    case text(String)
    case image(Data)

    var kind: ClipboardItemKind {
        switch self {
        case .text: return .text
        case .image: return .image
        }
    }

    var byteSize: Int {
        switch self {
        case .text(let text): return text.utf8.count
        case .image(let data): return data.count
        }
    }

    var contentHash: String {
        var hasher = SHA256()
        switch self {
        case .text(let text):
            hasher.update(data: Data([0x01]))
            hasher.update(data: Data(text.utf8))
        case .image(let data):
            hasher.update(data: Data([0x02]))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var previewText: String? {
        guard case .text(let text) = self else { return nil }
        return text.count <= 240 ? text : String(text.prefix(240))
    }

    var searchSnippet: String? {
        guard case .text(let text) = self else { return nil }
        return text.count <= 1_024 ? text : String(text.prefix(1_024))
    }

    var hasTruncatedText: Bool {
        guard case .text(let text) = self else { return false }
        return text.count > 1_024
    }

    func canStore(securityMode: SecurityMode = .sensitive) -> Bool {
        switch self {
        case .text(let text):
            guard text.utf8.count <= 2_000_000, text.count <= 100_000,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            if securityMode == .sensitive {
                return !ClipboardFilter.isSensitive(text) && !ClipboardFilter.containsFileURL(text)
            }
            return true
        case .image(let data):
            return data.count <= ClipboardFilter.maximumImageBytes
                && data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        }
    }
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: ClipboardItemKind
    let previewText: String?
    let searchSnippet: String?
    let hasTruncatedText: Bool
    let contentHash: String
    let byteSize: Int
    let date: Date
    let sourceBundleID: String?
    let isPinned: Bool

    var text: String? { previewText }

    init(
        id: UUID = UUID(),
        content: ClipboardContent,
        date: Date = Date(),
        sourceBundleID: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.kind = content.kind
        self.previewText = content.previewText
        self.searchSnippet = content.searchSnippet
        self.hasTruncatedText = content.hasTruncatedText
        self.contentHash = content.contentHash
        self.byteSize = content.byteSize
        self.date = date
        self.sourceBundleID = sourceBundleID
        self.isPinned = isPinned
    }

    init(
        id: UUID,
        kind: ClipboardItemKind,
        previewText: String?,
        searchSnippet: String?,
        hasTruncatedText: Bool,
        contentHash: String,
        byteSize: Int,
        date: Date,
        sourceBundleID: String?,
        isPinned: Bool
    ) {
        self.id = id
        self.kind = kind
        self.previewText = previewText
        self.searchSnippet = searchSnippet
        self.hasTruncatedText = hasTruncatedText
        self.contentHash = contentHash
        self.byteSize = byteSize
        self.date = date
        self.sourceBundleID = sourceBundleID
        self.isPinned = isPinned
    }

    func withPinned(_ pinned: Bool) -> ClipboardItem {
        ClipboardItem(
            id: id,
            kind: kind,
            previewText: previewText,
            searchSnippet: searchSnippet,
            hasTruncatedText: hasTruncatedText,
            contentHash: contentHash,
            byteSize: byteSize,
            date: date,
            sourceBundleID: sourceBundleID,
            isPinned: pinned
        )
    }

    fileprivate var hasValidMetadata: Bool {
        switch kind {
        case .text:
            guard byteSize > 0, byteSize <= 2_000_000, let previewText else { return false }
            return !previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image:
            return byteSize > 0 && byteSize <= ClipboardFilter.maximumImageBytes
        }
    }
}

struct HistoryStore {
    static let retention: TimeInterval = 24 * 60 * 60
    private static let byteLimit = 40_000_000
    static let defaultFileURL: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Kastor", isDirectory: true)
        .appendingPathComponent("history.encrypted")

    private(set) var entries: [ClipboardItem] = []
    private var memoryPayloads: [UUID: ClipboardContent] = [:]
    private let persistence: EncryptedHistory?
    private var limit: Int
    private(set) var autoDelete24Hours: Bool
    private(set) var securityMode: SecurityMode
    private(set) var nextExpiry: Date?

    var inMemoryPayloadCount: Int { memoryPayloads.count }

    init(
        fileURL: URL? = HistoryStore.defaultFileURL,
        limit: Int = 100,
        autoDelete24Hours: Bool = false,
        securityMode: SecurityMode = .sensitive,
        now: Date = Date(),
        keyProvider: @escaping () -> SymmetricKey? = HistoryKey.loadOrCreate
    ) {
        self.limit = max(0, limit)
        self.autoDelete24Hours = autoDelete24Hours
        self.securityMode = securityMode
        persistence = fileURL.flatMap { $0.isFileURL ? EncryptedHistory(fileURL: $0, keyProvider: keyProvider) : nil }
        if let fileURL, fileURL == Self.defaultFileURL {
            Self.removeLegacyHistory(from: fileURL.deletingLastPathComponent())
        }
        guard let persistence else { return }
        guard let saved = persistence.loadIndex() else {
            persistence.saveIndex([])
            return
        }
        let valid = saved.filter { $0.hasValidMetadata && $0.date <= now }
        entries = valid.filter(\.isPinned) + valid.filter { !$0.isPinned }
        if autoDelete24Hours {
            _ = expire(now: now)
        }
        trim()
        if entries != saved {
            saveRemovingOldSnapshotOnFailure()
        } else {
            persistence.prunePayloads(keeping: Set(entries.map(\.id)))
        }
    }

    @discardableResult
    mutating func add(_ text: String, sourceBundleID: String? = nil, now: Date = Date()) -> Bool {
        add(.text(text), sourceBundleID: sourceBundleID, now: now)
    }

    @discardableResult
    mutating func add(_ content: ClipboardContent, sourceBundleID: String? = nil, now: Date = Date()) -> Bool {
        guard limit > 0, content.canStore(securityMode: securityMode) else { return false }
        if autoDelete24Hours {
            _ = expire(now: now)
        }
        let hash = content.contentHash
        let existingPinned = entries.first { $0.kind == content.kind && $0.contentHash == hash }?.isPinned ?? false
        let duplicateIDs = entries.filter { $0.kind == content.kind && $0.contentHash == hash }.map(\.id)
        for duplicateID in duplicateIDs {
            memoryPayloads.removeValue(forKey: duplicateID)
        }
        entries.removeAll { $0.kind == content.kind && $0.contentHash == hash }

        let item = ClipboardItem(
            id: UUID(),
            content: content,
            date: now,
            sourceBundleID: sourceBundleID,
            isPinned: existingPinned
        )

        if let persistence, persistence.savePayload(content, for: item.id) {
            memoryPayloads.removeValue(forKey: item.id)
        } else {
            memoryPayloads[item.id] = content
        }

        let insertionIndex = existingPinned ? 0 : firstUnpinnedIndex
        entries.insert(item, at: insertionIndex)
        trim()
        return true
    }

    func loadContent(for id: UUID) -> ClipboardContent? {
        if let cached = memoryPayloads[id] {
            return cached
        }
        return persistence?.loadPayload(for: id)
    }

    func search(_ query: String) -> [ClipboardItem] {
        guard !query.isEmpty else { return entries }
        return entries.filter { item in
            guard item.kind == .text else { return false }
            if item.searchSnippet?.localizedCaseInsensitiveContains(query) == true {
                return true
            }
            if item.hasTruncatedText, case .text(let fullText) = loadContent(for: item.id) {
                return fullText.localizedCaseInsensitiveContains(query)
            }
            return false
        }
    }

    @discardableResult
    mutating func togglePin(_ id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let removed = entries.remove(at: index)
        let updated = removed.withPinned(!removed.isPinned)
        let targetIndex = updated.isPinned ? 0 : firstUnpinnedIndex
        entries.insert(updated, at: targetIndex)
        trim()
        return updated.isPinned
    }

    mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        memoryPayloads.removeValue(forKey: id)
        refreshExpiry()
    }

    mutating func clear() {
        entries.removeAll()
        memoryPayloads.removeAll()
        refreshExpiry()
        saveRemovingOldSnapshotOnFailure()
    }

    static func matches(_ date: Date, range: DeleteRange, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch range {
        case .today:
            return date >= calendar.startOfDay(for: now)
        case .yesterday:
            let startToday = calendar.startOfDay(for: now)
            guard let startYesterday = calendar.date(byAdding: .day, value: -1, to: startToday) else {
                return false
            }
            return date >= startYesterday && date < startToday
        case .lastWeek:
            guard let cutoff = calendar.date(byAdding: .day, value: -7, to: now) else {
                return false
            }
            return date >= cutoff
        case .allTime:
            return true
        }
    }

    func count(matching range: DeleteRange, now: Date = Date(), calendar: Calendar = .current) -> Int {
        entries.reduce(into: 0) { partial, item in
            if !item.isPinned && Self.matches(item.date, range: range, now: now, calendar: calendar) {
                partial += 1
            }
        }
    }

    @discardableResult
    mutating func delete(range: DeleteRange, now: Date = Date(), calendar: Calendar = .current) -> Int {
        var removedIDs: [UUID] = []
        entries.removeAll { item in
            let shouldRemove = !item.isPinned && Self.matches(item.date, range: range, now: now, calendar: calendar)
            if shouldRemove {
                removedIDs.append(item.id)
            }
            return shouldRemove
        }
        guard !removedIDs.isEmpty else { return 0 }
        for id in removedIDs {
            memoryPayloads.removeValue(forKey: id)
        }
        refreshExpiry()
        saveRemovingOldSnapshotOnFailure()
        return removedIDs.count
    }

    mutating func setLimit(_ limit: Int) {
        self.limit = max(0, limit)
        trim()
    }

    mutating func setSecurityMode(_ mode: SecurityMode) {
        self.securityMode = mode
    }

    @discardableResult
    mutating func setAutoDelete24Hours(_ enabled: Bool, now: Date = Date()) -> Bool {
        autoDelete24Hours = enabled
        if enabled {
            return expire(now: now)
        }
        nextExpiry = nil
        return false
    }

    @discardableResult
    mutating func expire(now: Date = Date()) -> Bool {
        guard autoDelete24Hours else {
            nextExpiry = nil
            return false
        }
        if let nextExpiry, now < nextExpiry { return false }
        let countBefore = entries.count
        entries.removeAll { item in
            guard !item.isPinned else { return false }
            let expired = item.date.addingTimeInterval(Self.retention) <= now
            if expired {
                memoryPayloads.removeValue(forKey: item.id)
            }
            return expired
        }
        refreshExpiry()
        return countBefore != entries.count
    }

    func save() {
        persistence?.saveIndex(entries)
    }

    func saveRemovingOldSnapshotOnFailure() {
        guard let persistence, !persistence.saveIndex(entries), !entries.isEmpty else { return }
        persistence.saveIndex([])
    }

    mutating func moveToTop(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let item = entries[index]
        let targetIndex = item.isPinned ? 0 : firstUnpinnedIndexExcluding(index)
        guard index != targetIndex else { return }
        entries.remove(at: index)
        entries.insert(item, at: targetIndex)
    }

    private var firstUnpinnedIndex: Int {
        entries.firstIndex(where: { !$0.isPinned }) ?? entries.count
    }

    private func firstUnpinnedIndexExcluding(_ removedIndex: Int) -> Int {
        var unpinnedOffset = 0
        for (idx, entry) in entries.enumerated() where idx != removedIndex {
            if !entry.isPinned { return unpinnedOffset }
            unpinnedOffset += 1
        }
        return unpinnedOffset
    }

    private mutating func trim() {
        let pinned = entries.filter(\.isPinned)
        let unpinned = Array(entries.filter { !$0.isPinned }.prefix(limit))
        let candidates = pinned + unpinned

        var bytes = 0
        var kept: [ClipboardItem] = []
        kept.reserveCapacity(candidates.count)
        for item in candidates {
            if bytes + item.byteSize <= Self.byteLimit {
                bytes += item.byteSize
                kept.append(item)
            } else {
                memoryPayloads.removeValue(forKey: item.id)
            }
        }
        let keptIDs = Set(kept.map(\.id))
        for entry in entries where !keptIDs.contains(entry.id) {
            memoryPayloads.removeValue(forKey: entry.id)
        }
        entries = kept
        refreshExpiry()
    }

    private mutating func refreshExpiry() {
        guard autoDelete24Hours else {
            nextExpiry = nil
            return
        }
        nextExpiry = entries.lazy.filter { !$0.isPinned }.map(\.date).min()?.addingTimeInterval(Self.retention)
    }

    private static func removeLegacyHistory(from directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory.appendingPathComponent("history.json"))
        guard let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for child in children where child.lastPathComponent.hasPrefix(".history-") {
            let suffix = child.lastPathComponent.dropFirst(".history-".count)
            if UUID(uuidString: String(suffix)) != nil { try? fileManager.removeItem(at: child) }
        }
    }
}
