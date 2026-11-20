import Foundation
import Observation

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case delete

    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    static let historySizes = [50, 100, 200, 500]

    private let preferences: KastorPreferences
    private var store: HistoryStore
    private let monitor = ClipboardMonitor()
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var expiryTimer: Timer?
    private var needsSave = false

    var popoverOpenCount = 0
    var popoverSessionID = UUID()
    var selectedSettingsTab: SettingsTab = .general
    var closePopover: (() -> Void)?
    var openSettings: ((SettingsTab) -> Void)?
    var onLanguageChange: ((AppLanguage) -> Void)?

    private(set) var historySize: Int
    private(set) var securityMode: SecurityMode
    private(set) var autoDelete24Hours: Bool
    private(set) var language: AppLanguage

    var entries: [ClipboardItem] { store.entries }
    var pinnedCount: Int { store.entries.reduce(into: 0) { if $1.isPinned { $0 += 1 } } }

    init(preferences: KastorPreferences = KastorPreferences()) {
        self.preferences = preferences
        let initialSize = preferences.historySize
        let initialSecurity = preferences.securityMode
        let initialAutoDelete = preferences.autoDelete24Hours
        let initialLanguage = preferences.language

        self.historySize = initialSize
        self.securityMode = initialSecurity
        self.autoDelete24Hours = initialAutoDelete
        self.language = initialLanguage
        self.store = HistoryStore(
            limit: initialSize,
            autoDelete24Hours: initialAutoDelete,
            securityMode: initialSecurity
        )

        monitor.securityModeProvider = { [weak self] in
            self?.securityMode ?? .sensitive
        }
        monitor.onNewContent = { [weak self] content, source in
            guard let self else { return }
            let now = Date()
            self.refreshRetention(now: now)
            let originalCount = self.store.entries.count
            guard self.store.add(content, sourceBundleID: source, now: now) else { return }
            if self.store.entries.count <= originalCount {
                self.persistRemoval()
            } else {
                self.scheduleSave()
            }
            self.scheduleExpiry(now: now)
        }
        scheduleExpiry()
        monitor.start()
    }

    func search(_ query: String) -> [ClipboardItem] {
        store.search(query)
    }

    func loadImageData(for id: UUID) -> Data? {
        guard case .image(let data) = store.loadContent(for: id) else { return nil }
        return data
    }

    func copy(_ item: ClipboardItem) {
        refreshRetention()
        guard store.entries.contains(where: { $0.id == item.id }),
              let content = store.loadContent(for: item.id) else { return }
        guard monitor.write(content) else { return }
        store.moveToTop(item.id)
        scheduleSave()
        closePopover?()
    }

    func togglePin(_ id: UUID) {
        store.togglePin(id)
        persistRemoval()
        scheduleExpiry()
    }

    func remove(_ id: UUID) {
        store.remove(id)
        persistRemoval()
        scheduleExpiry()
    }

    func clear() {
        pendingSave?.cancel()
        pendingSave = nil
        needsSave = false
        store.clear()
        scheduleExpiry()
    }

    func countForDelete(_ range: DeleteRange) -> Int {
        store.count(matching: range)
    }

    @discardableResult
    func deleteHistory(range: DeleteRange) -> Int {
        pendingSave?.cancel()
        pendingSave = nil
        needsSave = false
        let deleted = store.delete(range: range)
        scheduleExpiry()
        return deleted
    }

    func setHistorySize(_ size: Int) {
        guard Self.historySizes.contains(size), size != historySize else { return }
        historySize = size
        preferences.historySize = size
        store.setLimit(size)
        persistRemoval()
        scheduleExpiry()
    }

    func setSecurityMode(_ mode: SecurityMode) {
        guard mode != securityMode else { return }
        securityMode = mode
        preferences.securityMode = mode
        store.setSecurityMode(mode)
    }

    func setAutoDelete24Hours(_ enabled: Bool) {
        guard enabled != autoDelete24Hours else { return }
        autoDelete24Hours = enabled
        preferences.autoDelete24Hours = enabled
        if store.setAutoDelete24Hours(enabled) {
            persistRemoval()
        }
        scheduleExpiry()
    }

    func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        preferences.language = newLanguage
        onLanguageChange?(newLanguage)
    }

    func releaseTransientMemory() {
        popoverSessionID = UUID()
    }

    func flush() {
        refreshRetention()
        pendingSave?.cancel()
        pendingSave = nil
        persistIfNeeded()
    }

    func refreshRetention(now: Date = Date()) {
        guard autoDelete24Hours else {
            expiryTimer?.invalidate()
            expiryTimer = nil
            return
        }
        if store.expire(now: now) { persistRemoval() }
        scheduleExpiry(now: now)
    }

    private func scheduleExpiry(now: Date = Date()) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard autoDelete24Hours, let expires = store.nextExpiry else { return }
        let timer = Timer(timeInterval: max(0.01, expires.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRetention() }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    private func persistRemoval() {
        pendingSave?.cancel()
        pendingSave = nil
        needsSave = false
        store.saveRemovingOldSnapshotOnFailure()
    }

    private func scheduleSave() {
        needsSave = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                self?.persistIfNeeded()
            } catch {}
        }
    }

    private func persistIfNeeded() {
        guard needsSave else { return }
        store.save()
        needsSave = false
    }
}
