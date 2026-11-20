import AppKit

@MainActor
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private var isNormalizingImage = false

    var securityModeProvider: () -> SecurityMode = { .sensitive }
    var onNewContent: ((ClipboardContent, String?) -> Void)?

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.poll()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @discardableResult
    func write(_ content: ClipboardContent) -> Bool {
        pasteboard.clearContents()
        let didWrite: Bool
        switch content {
        case .text(let text):
            didWrite = pasteboard.setString(text, forType: .string)
        case .image(let data):
            didWrite = pasteboard.setData(data, forType: .png)
        }
        lastChangeCount = pasteboard.changeCount
        return didWrite
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount, !isNormalizingImage else { return }
        lastChangeCount = count

        guard let advertisedTypes = pasteboard.types else { return }
        let types = Set(advertisedTypes.map(\.rawValue))
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let securityMode = securityModeProvider()

        guard ClipboardFilter.shouldRecord(types: types, sourceBundleID: frontmost, securityMode: securityMode),
              (securityMode == .normal || metadataAllowsCapture(types: types)),
              pasteboard.changeCount == count else { return }

        let text: String?
        if types.contains(NSPasteboard.PasteboardType.string.rawValue) {
            guard let plainText = pasteboard.string(forType: .string),
                  plainText.utf8.count <= 2_000_000, plainText.count <= 100_000 else { return }
            if securityMode == .sensitive,
               ClipboardFilter.isSensitive(plainText) || ClipboardFilter.containsFileURL(plainText) {
                return
            }
            text = ClipboardFilter.allowsTextFallback(types: types) ? plainText : nil
        } else {
            text = nil
        }

        guard pasteboard.changeCount == count else { return }
        let imageTypes = ClipboardFilter.imageTypesInPreferenceOrder.filter(types.contains)
        guard !imageTypes.isEmpty else {
            if let text { onNewContent?(.text(text), frontmost) }
            return
        }

        // Allow a single decode in flight. The next poll can pick up a newer clipboard change.
        isNormalizingImage = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isNormalizingImage = false }
            let image = await self.readImage(types: imageTypes, changeCount: count)
            guard self.pasteboard.changeCount == count else { return }
            if let image {
                self.onNewContent?(.image(image), frontmost)
            } else if let text {
                self.onNewContent?(.text(text), frontmost)
            }
        }
    }

    private func metadataAllowsCapture(types: Set<String>) -> Bool {
        let sourceType = NSPasteboard.PasteboardType(ClipboardFilter.sourceType)
        let hasSource = types.contains(sourceType.rawValue)
        let hasURL = types.contains(NSPasteboard.PasteboardType.URL.rawValue)
        guard hasSource || hasURL else { return true }
        guard let items = pasteboard.pasteboardItems else { return false }
        return !items.contains { item in
            ClipboardFilter.isIgnoredApp(item.string(forType: sourceType))
                || item.string(forType: .URL).map(ClipboardFilter.containsFileURL) == true
        }
    }

    private func readImage(types: [String], changeCount: Int) async -> Data? {
        for type in types {
            guard pasteboard.changeCount == changeCount else { return nil }
            guard let data = pasteboard.data(forType: .init(type)),
                  data.count <= ClipboardFilter.maximumImageBytes else { continue }
            guard pasteboard.changeCount == changeCount else { return nil }
            let png = await Task.detached(priority: .utility) {
                ClipboardFilter.normalizedPNG(from: data, advertisedType: type)
            }.value
            if let png { return png }
        }
        return nil
    }
}
