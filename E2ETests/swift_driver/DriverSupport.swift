import AppKit
import ApplicationServices
import Foundation
import SwiftUI

enum DriverStatus: String, Codable {
    case PASS
    case FAIL
    case PENDING_IMPL
    case ERROR
}

struct DriverCaseResult: Codable {
    let id: String
    let status: DriverStatus
    let message: String
    let durationMs: Double
    let metrics: [String: String]

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case message
        case durationMs = "duration_ms"
        case metrics
    }

    static func pass(
        id: String,
        message: String,
        durationMs: Double = 0,
        metrics: [String: String] = [:]
    ) -> DriverCaseResult {
        DriverCaseResult(
            id: id,
            status: .PASS,
            message: message,
            durationMs: durationMs,
            metrics: metrics
        )
    }

    static func fail(
        id: String,
        message: String,
        durationMs: Double = 0,
        metrics: [String: String] = [:]
    ) -> DriverCaseResult {
        DriverCaseResult(
            id: id,
            status: .FAIL,
            message: message,
            durationMs: durationMs,
            metrics: metrics
        )
    }

    static func pending(
        id: String,
        message: String,
        durationMs: Double = 0,
        metrics: [String: String] = [:]
    ) -> DriverCaseResult {
        DriverCaseResult(
            id: id,
            status: .PENDING_IMPL,
            message: message,
            durationMs: durationMs,
            metrics: metrics
        )
    }

    static func error(
        id: String,
        message: String,
        durationMs: Double = 0,
        metrics: [String: String] = [:]
    ) -> DriverCaseResult {
        DriverCaseResult(
            id: id,
            status: .ERROR,
            message: message,
            durationMs: durationMs,
            metrics: metrics
        )
    }
}

struct SwiftDriverCaseMeta: Codable {
    let id: String
    let tier: Int
    let feature: String
    let title: String
}

struct SwiftDriverCase {
    let id: String
    let tier: Int
    let feature: String
    let title: String
    let run: @MainActor (IsolatedTestEnvironment) throws -> DriverCaseResult

    var metadata: SwiftDriverCaseMeta {
        SwiftDriverCaseMeta(id: id, tier: tier, feature: feature, title: title)
    }
}

struct DriverFailure: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

enum DriverAssert {
    static func isTrue(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw DriverFailure(message)
        }
    }

    static func isFalse(_ condition: Bool, _ message: String) throws {
        if condition {
            throw DriverFailure(message)
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "Assertion") throws {
        if actual != expected {
            throw DriverFailure("\(label): expected \(expected), got \(actual)")
        }
    }

    static func notEqual<T: Equatable>(_ actual: T, _ unexpected: T, _ label: String = "Assertion") throws {
        if actual == unexpected {
            throw DriverFailure("\(label): expected value != \(unexpected)")
        }
    }

    static func near(_ actual: Double, _ expected: Double, tolerance: Double, _ label: String = "Assertion") throws {
        if abs(actual - expected) > tolerance {
            throw DriverFailure("\(label): expected \(expected) ± \(tolerance), got \(actual)")
        }
    }

    @discardableResult
    static func notNil<T>(_ value: T?, _ message: String) throws -> T {
        guard let unwrapped = value else {
            throw DriverFailure(message)
        }
        return unwrapped
    }
}

enum DriverAppRuntime {
    @MainActor
    private static var initialized = false

    @MainActor
    static func ensureInitialized() {
        guard !initialized else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        initialized = true
    }
}

final class IsolatedTestEnvironment {
    let rootURL: URL
    let appSupportURL: URL
    let historyFileURL: URL
    let payloadsDirectoryURL: URL
    let userDefaultsSuiteName: String
    private var createdPasteboards: [NSPasteboard] = []

    init() throws {
        let base = FileManager.default.temporaryDirectory
        self.rootURL = base.appendingPathComponent("kastor-e2e-\(UUID().uuidString)", isDirectory: true)
        self.appSupportURL = rootURL.appendingPathComponent("ApplicationSupport/Kastor", isDirectory: true)
        self.historyFileURL = appSupportURL.appendingPathComponent("history.encrypted", isDirectory: false)
        self.payloadsDirectoryURL = appSupportURL.appendingPathComponent("payloads", isDirectory: true)
        self.userDefaultsSuiteName = "com.kastor.e2e.\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
    }

    func makeUserDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: userDefaultsSuiteName) ?? UserDefaults.standard
        defaults.removePersistentDomain(forName: userDefaultsSuiteName)
        return defaults
    }

    func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.kastor.e2e.\(UUID().uuidString)"))
        pb.clearContents()
        createdPasteboards.append(pb)
        return pb
    }

    func cleanup() {
        for pb in createdPasteboards {
            pb.clearContents()
            pb.releaseGlobally()
        }
        createdPasteboards.removeAll()
        UserDefaults.standard.removePersistentDomain(forName: userDefaultsSuiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

final class PasteboardBackup {
    private var snapshot: [[NSPasteboard.PasteboardType: Data]] = []

    init() {
        capture()
    }

    func capture() {
        snapshot.removeAll()
        guard let items = NSPasteboard.general.pasteboardItems else { return }
        for item in items {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            if !dict.isEmpty {
                snapshot.append(dict)
            }
        }
    }

    func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        var restoredItems: [NSPasteboardItem] = []
        for entry in snapshot {
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            restoredItems.append(item)
        }
        pb.writeObjects(restoredItems)
    }
}

@MainActor
final class OffscreenWindowHost {
    let window: NSWindow
    let rootView: NSView

    init<V: View>(
        rootView view: V,
        size: CGSize,
        appearanceName: NSAppearance.Name = .aqua
    ) {
        DriverAppRuntime.ensureInitialized()
        let hostingController = NSHostingController(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.colorSpace = .sRGB
        win.appearance = NSAppearance(named: appearanceName)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.contentViewController = hostingController
        win.orderBack(nil)
        win.contentView?.layoutSubtreeIfNeeded()
        self.window = win
        self.rootView = hostingController.view
        pumpRunLoop(seconds: 0.05)
    }

    func pumpRunLoop(seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func captureSRGBBitmap() -> NSBitmapImageRep? {
        rootView.layoutSubtreeIfNeeded()
        let bounds = rootView.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = rootView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        rootView.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}

enum PixelSampler {
    static let kastorPaperRGB = (238, 234, 246)
    static let kastorInkRGB = (27, 19, 43)

    static func sRGBPixel(
        in rep: NSBitmapImageRep,
        point: CGPoint,
        viewBounds: CGRect
    ) -> (r: Int, g: Int, b: Int, a: Int)? {
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0,
              viewBounds.width > 0, viewBounds.height > 0 else {
            return nil
        }
        let scaleX = CGFloat(rep.pixelsWide) / viewBounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / viewBounds.height
        let pxX = max(0, min(rep.pixelsWide - 1, Int((point.x * scaleX).rounded(.down))))
        let pxY = max(0, min(rep.pixelsHigh - 1, Int((point.y * scaleY).rounded(.down))))
        var px = [Int](repeating: 0, count: max(4, rep.samplesPerPixel))
        rep.getPixel(&px, atX: pxX, y: pxY)
        let alpha = rep.samplesPerPixel >= 4 ? px[3] : 255
        return (px[0], px[1], px[2], alpha)
    }

    static func matchesRGB(
        _ px: (r: Int, g: Int, b: Int, a: Int),
        target: (Int, Int, Int),
        tolerance: Int = 2
    ) -> Bool {
        abs(px.r - target.0) <= tolerance &&
        abs(px.g - target.1) <= tolerance &&
        abs(px.b - target.2) <= tolerance
    }

    static func containsColor(
        in rep: NSBitmapImageRep,
        target: (Int, Int, Int),
        tolerance: Int = 3
    ) -> Bool {
        var px = [Int](repeating: 0, count: max(4, rep.samplesPerPixel))
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                rep.getPixel(&px, atX: x, y: y)
                let alpha = rep.samplesPerPixel >= 4 ? px[3] : 255
                if alpha > 20 &&
                    abs(px[0] - target.0) <= tolerance &&
                    abs(px[1] - target.1) <= tolerance &&
                    abs(px[2] - target.2) <= tolerance {
                    return true
                }
            }
        }
        return false
    }
}

enum TrayRasterComparator {
    static func rasterizeAlpha(image: NSImage, size: Int) -> [UInt8]? {
        guard size > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: size,
                pixelsHigh: size,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: size * 4,
                bitsPerPixel: 32
              ) else {
            return nil
        }
        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var alphas = [UInt8]()
        alphas.reserveCapacity(size * size)
        var px = [Int](repeating: 0, count: 4)
        for y in 0..<size {
            for x in 0..<size {
                rep.getPixel(&px, atX: x, y: y)
                alphas.append(UInt8(max(0, min(255, px[3]))))
            }
        }
        return alphas
    }

    static func compareTrayImage(
        _ image: NSImage,
        againstReferencePNG path: String,
        size: Int
    ) -> (maxAlphaDiff: Int, mae: Double)? {
        guard let refImage = NSImage(contentsOfFile: path),
              let actualAlpha = rasterizeAlpha(image: image, size: size),
              let refAlpha = rasterizeAlpha(image: refImage, size: size),
              actualAlpha.count == refAlpha.count,
              !actualAlpha.isEmpty else {
            return nil
        }
        var totalDiff = 0
        var maxDiff = 0
        for (a, b) in zip(actualAlpha, refAlpha) {
            let diff = abs(Int(a) - Int(b))
            totalDiff += diff
            if diff > maxDiff {
                maxDiff = diff
            }
        }
        let mae = Double(totalDiff) / Double(actualAlpha.count)
        return (maxAlphaDiff: maxDiff, mae: mae)
    }
}

struct AXNode {
    let role: String
    let identifier: String
    let title: String
    let description: String
    let help: String
    let value: String
    let frame: CGRect
    let element: AXUIElement
    let children: [AXNode]
}

enum AXTreeInspector {
    private static func copyString(_ element: AXUIElement, attribute: CFString) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let val = ref else {
            return ""
        }
        if let str = val as? String {
            return str
        }
        if let num = val as? NSNumber {
            return num.stringValue
        }
        return ""
    }

    private static func copyPoint(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let axVal = ref,
              CFGetTypeID(axVal) == AXValueGetTypeID() else {
            return nil
        }
        var pt = CGPoint.zero
        let ok = AXValueGetValue(axVal as! AXValue, .cgPoint, &pt)
        return ok ? pt : nil
    }

    private static func copySize(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let axVal = ref,
              CFGetTypeID(axVal) == AXValueGetTypeID() else {
            return nil
        }
        var sz = CGSize.zero
        let ok = AXValueGetValue(axVal as! AXValue, .cgSize, &sz)
        return ok ? sz : nil
    }

    private static func buildNode(_ element: AXUIElement, depth: Int = 0) -> AXNode {
        let role = copyString(element, attribute: kAXRoleAttribute as CFString)
        let identifier = copyString(element, attribute: kAXIdentifierAttribute as CFString)
        let title = copyString(element, attribute: kAXTitleAttribute as CFString)
        let description = copyString(element, attribute: kAXDescriptionAttribute as CFString)
        let help = copyString(element, attribute: kAXHelpAttribute as CFString)
        let value = copyString(element, attribute: kAXValueAttribute as CFString)
        let pos = copyPoint(element, attribute: kAXPositionAttribute as CFString) ?? .zero
        let size = copySize(element, attribute: kAXSizeAttribute as CFString) ?? .zero
        let frame = CGRect(origin: pos, size: size)

        var children: [AXNode] = []
        if depth < 24 {
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let rawChildren = childrenRef as? [AXUIElement] {
                children = rawChildren.map { buildNode($0, depth: depth + 1) }
            }
        }

        return AXNode(
            role: role,
            identifier: identifier,
            title: title,
            description: description,
            help: help,
            value: value,
            frame: frame,
            element: element,
            children: children
        )
    }

    static func windows(forPID pid: pid_t = getpid()) -> [AXNode] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return []
        }
        return axWindows.map { buildNode($0) }
    }

    @MainActor
    static func windowNode(matchingWindow window: NSWindow) -> AXNode? {
        let targetFrame = window.frame
        let allWindows = windows()
        return allWindows.first { node in
            abs(node.frame.minX - targetFrame.minX) < 3.0 &&
            abs(node.frame.width - targetFrame.width) < 3.0 &&
            abs(node.frame.height - targetFrame.height) < 3.0
        } ?? allWindows.first { node in
            abs(node.frame.width - targetFrame.width) < 3.0 &&
            abs(node.frame.height - targetFrame.height) < 3.0
        }
    }

    static func findAll(in root: AXNode, matching predicate: (AXNode) -> Bool) -> [AXNode] {
        var result: [AXNode] = []
        if predicate(root) {
            result.append(root)
        }
        for child in root.children {
            result.append(contentsOf: findAll(in: child, matching: predicate))
        }
        return result
    }

    static func find(in root: AXNode, identifier: String) -> AXNode? {
        if root.identifier == identifier {
            return root
        }
        for child in root.children {
            if let hit = find(in: child, identifier: identifier) {
                return hit
            }
        }
        return nil
    }

    @discardableResult
    static func press(_ node: AXNode) -> Bool {
        AXUIElementPerformAction(node.element, kAXPressAction as CFString) == .success
    }

    static func isImmediatelyLeftOf(_ left: CGRect, _ right: CGRect, maxGap: CGFloat = 24) -> Bool {
        left.maxX <= right.minX + 1.0 && (right.minX - left.maxX) <= maxGap
    }

    static func isImmediatelyRightOf(_ right: CGRect, _ left: CGRect, maxGap: CGFloat = 24) -> Bool {
        right.minX >= left.maxX - 1.0 && (right.minX - left.maxX) <= maxGap
    }
}

enum ViewTreeInspector {
    @MainActor
    static func findSubviews<T: NSView>(in root: NSView, ofType type: T.Type = T.self) -> [T] {
        var matches: [T] = []
        if let typed = root as? T {
            matches.append(typed)
        }
        for subview in root.subviews {
            matches.append(contentsOf: findSubviews(in: subview, ofType: type))
        }
        return matches
    }
}

private struct SelfTestHarnessView: View {
    @State private var showSearch = false
    @State private var query = ""

    var body: some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(Color(red: 27.0 / 255.0, green: 19.0 / 255.0, blue: 43.0 / 255.0))
                .frame(width: 80, height: 18)
            if showSearch {
                TextField("Search", text: $query)
                    .accessibilityIdentifier("search.field")
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Search") {
                    showSearch.toggle()
                }
                .accessibilityIdentifier("footer.search")
                .help("Search tooltip")

                Button("Settings") {}
                    .accessibilityIdentifier("footer.settings")
                    .help("Settings tooltip")
            }
        }
        .padding(12)
        .frame(width: 320, height: showSearch ? 140 : 100)
        .background(Color(red: 238.0 / 255.0, green: 234.0 / 255.0, blue: 246.0 / 255.0))
    }
}

enum DriverSelfTest {
    @MainActor
    static func run(assetsDir: String?) -> DriverCaseResult {
        let start = CFAbsoluteTimeGetCurrent()
        var metrics: [String: String] = [:]

        do {
            DriverAppRuntime.ensureInitialized()

            // 1. Isolated environment + cleanup verification
            let env = try IsolatedTestEnvironment()
            let rootPath = env.rootURL.path
            let markerFile = env.appSupportURL.appendingPathComponent("probe.tmp")
            try Data("kastor".utf8).write(to: markerFile)
            let defaults = env.makeUserDefaults()
            defaults.set("tr", forKey: "kastor.self_test.lang")
            try DriverAssert.equal(defaults.string(forKey: "kastor.self_test.lang"), "tr", "UserDefaults suite write/read")
            let pb = env.makePasteboard()
            pb.setString("probe-value", forType: .string)
            try DriverAssert.equal(pb.string(forType: .string), "probe-value", "Isolated NSPasteboard write/read")
            env.cleanup()
            try DriverAssert.isFalse(FileManager.default.fileExists(atPath: rootPath), "IsolatedTestEnvironment cleanup failed")
            metrics["isolation"] = "ok"

            // 2. OffscreenWindowHost + PixelSampler + AXTreeInspector (LTR)
            let ltrHost = OffscreenWindowHost(
                rootView: SelfTestHarnessView(),
                size: CGSize(width: 320, height: 100),
                appearanceName: .aqua
            )
            defer { ltrHost.close() }

            let rep = try DriverAssert.notNil(ltrHost.captureSRGBBitmap(), "Failed to capture sRGB bitmap")
            let paperPx = try DriverAssert.notNil(
                PixelSampler.sRGBPixel(in: rep, point: CGPoint(x: 8, y: 8), viewBounds: ltrHost.rootView.bounds),
                "Failed to sample paper pixel"
            )
            try DriverAssert.isTrue(
                PixelSampler.matchesRGB(paperPx, target: PixelSampler.kastorPaperRGB, tolerance: 2),
                "Paper pixel \(paperPx) did not match #EEEAF6"
            )
            try DriverAssert.isTrue(
                PixelSampler.containsColor(in: rep, target: PixelSampler.kastorInkRGB, tolerance: 3),
                "Ink #1B132B not found in rendered bitmap"
            )
            metrics["pixel_sampling"] = "ok"

            let ltrWinNode = try DriverAssert.notNil(
                AXTreeInspector.windowNode(matchingWindow: ltrHost.window),
                "AX window node not found for offscreen window"
            )
            let searchBtn = try DriverAssert.notNil(
                AXTreeInspector.find(in: ltrWinNode, identifier: "footer.search"),
                "footer.search not found in AX tree"
            )
            let settingsBtn = try DriverAssert.notNil(
                AXTreeInspector.find(in: ltrWinNode, identifier: "footer.settings"),
                "footer.settings not found in AX tree"
            )
            try DriverAssert.equal(searchBtn.help, "Search tooltip", "Search tooltip")
            try DriverAssert.equal(settingsBtn.help, "Settings tooltip", "Settings tooltip")
            try DriverAssert.isTrue(
                AXTreeInspector.isImmediatelyLeftOf(searchBtn.frame, settingsBtn.frame, maxGap: 24),
                "LTR search button frame \(searchBtn.frame) not immediately left of settings \(settingsBtn.frame)"
            )
            try DriverAssert.isTrue(
                AXTreeInspector.find(in: ltrWinNode, identifier: "search.field") == nil,
                "search.field must be hidden before toggle"
            )

            let pressed = AXTreeInspector.press(searchBtn)
            try DriverAssert.isTrue(pressed, "AXPress failed on footer.search")
            ltrHost.pumpRunLoop(seconds: 0.05)

            let postPressWin = try DriverAssert.notNil(
                AXTreeInspector.windowNode(matchingWindow: ltrHost.window),
                "AX window node disappeared after AXPress"
            )
            try DriverAssert.isTrue(
                AXTreeInspector.find(in: postPressWin, identifier: "search.field") != nil,
                "search.field did not appear after AXPress"
            )
            metrics["ax_ltr_toggle"] = "ok"

            // 3. RTL AX layout verification
            let rtlHost = OffscreenWindowHost(
                rootView: SelfTestHarnessView().environment(\.layoutDirection, .rightToLeft),
                size: CGSize(width: 320, height: 100),
                appearanceName: .aqua
            )
            defer { rtlHost.close() }
            let rtlWinNode = try DriverAssert.notNil(
                AXTreeInspector.windowNode(matchingWindow: rtlHost.window),
                "AX window node not found for RTL offscreen window"
            )
            let rtlSearch = try DriverAssert.notNil(
                AXTreeInspector.find(in: rtlWinNode, identifier: "footer.search"),
                "RTL footer.search not found"
            )
            let rtlSettings = try DriverAssert.notNil(
                AXTreeInspector.find(in: rtlWinNode, identifier: "footer.settings"),
                "RTL footer.settings not found"
            )
            try DriverAssert.isTrue(
                AXTreeInspector.isImmediatelyRightOf(rtlSearch.frame, rtlSettings.frame, maxGap: 24),
                "RTL search button frame \(rtlSearch.frame) not immediately right of settings \(rtlSettings.frame)"
            )
            metrics["ax_rtl_layout"] = "ok"

            // 4. TrayRasterComparator verification against reference PNGs + negative blank check
            if let dir = assetsDir, !dir.isEmpty {
                let tray18Path = (dir as NSString).appendingPathComponent("TrayOption-D-18.png")
                let tray36Path = (dir as NSString).appendingPathComponent("TrayOption-D-36.png")
                if FileManager.default.fileExists(atPath: tray18Path) &&
                    FileManager.default.fileExists(atPath: tray36Path) {
                    let img18 = try DriverAssert.notNil(NSImage(contentsOfFile: tray18Path), "Failed to load TrayOption-D-18.png")
                    let img36 = try DriverAssert.notNil(NSImage(contentsOfFile: tray36Path), "Failed to load TrayOption-D-36.png")
                    let cmp18 = try DriverAssert.notNil(
                        TrayRasterComparator.compareTrayImage(img18, againstReferencePNG: tray18Path, size: 18),
                        "compareTrayImage 18 failed"
                    )
                    let cmp36 = try DriverAssert.notNil(
                        TrayRasterComparator.compareTrayImage(img36, againstReferencePNG: tray36Path, size: 36),
                        "compareTrayImage 36 failed"
                    )
                    try DriverAssert.equal(cmp18.maxAlphaDiff, 0, "Tray 18 self maxAlphaDiff")
                    try DriverAssert.equal(cmp36.maxAlphaDiff, 0, "Tray 36 self maxAlphaDiff")

                    let blank18 = NSImage(size: NSSize(width: 18, height: 18))
                    let blankCmp = try DriverAssert.notNil(
                        TrayRasterComparator.compareTrayImage(blank18, againstReferencePNG: tray18Path, size: 18),
                        "Blank tray comparison failed"
                    )
                    try DriverAssert.isTrue(blankCmp.mae > 10.0, "Blank image should mismatch TrayOption-D-18.png (mae=\(blankCmp.mae))")
                    metrics["tray_comparator"] = "ok"
                } else {
                    metrics["tray_comparator"] = "skipped_missing_assets"
                }
            } else {
                metrics["tray_comparator"] = "skipped_no_assets_dir"
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return DriverCaseResult.pass(
                id: "__self_test__",
                message: "DriverSupport self-test passed (isolation, sRGB pixel sampling, LTR/RTL AX + AXPress, TrayRasterComparator)",
                durationMs: elapsed,
                metrics: metrics
            )
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return DriverCaseResult.fail(
                id: "__self_test__",
                message: "DriverSupport self-test failed: \(error)",
                durationMs: elapsed,
                metrics: metrics
            )
        }
    }
}
