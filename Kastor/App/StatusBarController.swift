import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppModel
    private lazy var hostingController = NSHostingController(
        rootView: makePopoverView(maximumHeight: PopoverView.maximumHeight)
    )

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        hostingController.sizingOptions = []
        popover.contentViewController = hostingController

        if let button = statusItem.button {
            button.image = Self.statusImage()
            button.target = self
            button.action = #selector(toggle)
        }
        updateLocalization()

        model.closePopover = { [weak self] in self?.popover.performClose(nil) }
        Hotkey.register { [weak self] in self?.toggle() }
    }

    func updateLocalization() {
        guard let button = statusItem.button else { return }
        let label = L10n.string(.statusTitle, model.language)
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    // Approved Option D ("Antik Parşömen Pano") monochrome template silhouette (18x18 pt, Y-up 100x100 space)
    private static func statusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: 18.0 / 100.0, y: 18.0 / 100.0)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // Back twin sheet peeking bottom-left
            let back = CGMutablePath()
            back.move(to: CGPoint(x: 13.0, y: 66.0))
            back.addLine(to: CGPoint(x: 13.0, y: 19.0))
            back.addArc(tangent1End: CGPoint(x: 13.0, y: 10.0), tangent2End: CGPoint(x: 22.0, y: 10.0), radius: 9.0)
            back.addLine(to: CGPoint(x: 68.0, y: 10.0))
            ctx.setLineWidth(7.2)
            ctx.addPath(back)
            ctx.strokePath()

            // Front classical scroll body
            let body = CGMutablePath()
            body.move(to: CGPoint(x: 31.0, y: 74.0))
            body.addLine(to: CGPoint(x: 31.0, y: 33.0))
            body.addArc(tangent1End: CGPoint(x: 31.0, y: 24.0), tangent2End: CGPoint(x: 40.0, y: 24.0), radius: 9.0)
            body.addLine(to: CGPoint(x: 77.0, y: 24.0))
            body.addArc(tangent1End: CGPoint(x: 86.0, y: 24.0), tangent2End: CGPoint(x: 86.0, y: 33.0), radius: 9.0)
            body.addLine(to: CGPoint(x: 86.0, y: 74.0))
            ctx.setLineWidth(7.4)
            ctx.addPath(body)
            ctx.strokePath()

            // Flush rolled scroll header
            let scrollRoll = CGRect(x: 23.0, y: 74.0, width: 71.0, height: 16.5)
            ctx.setLineWidth(7.0)
            ctx.addPath(CGPath(roundedRect: scrollRoll, cornerWidth: 8.25, cornerHeight: 8.25, transform: nil))
            ctx.strokePath()

            // Classical scroll end-cap dots
            ctx.fillEllipse(in: CGRect(x: 28.0, y: 79.0, width: 6.5, height: 6.5))
            ctx.fillEllipse(in: CGRect(x: 82.5, y: 79.0, width: 6.5, height: 6.5))

            // Two copied-entry lines
            ctx.setLineWidth(7.0)
            ctx.move(to: CGPoint(x: 44.0, y: 55.5))
            ctx.addLine(to: CGPoint(x: 73.0, y: 55.5))
            ctx.strokePath()

            ctx.move(to: CGPoint(x: 44.0, y: 40.5))
            ctx.addLine(to: CGPoint(x: 64.0, y: 40.5))
            ctx.strokePath()

            return true
        }
        image.isTemplate = true
        return image
    }

    func show() {
        guard !popover.isShown, let button = statusItem.button else { return }
        let view = makePopoverView(maximumHeight: maximumHeight(below: button))
        hostingController.rootView = view
        popover.contentSize = view.contentSize(for: model.entries.count, isSearching: false)
        model.popoverOpenCount += 1
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        model.releaseTransientMemory()
    }

    private func makePopoverView(maximumHeight: CGFloat) -> PopoverView {
        PopoverView(model: model, maximumHeight: maximumHeight) { [weak self] size in
            guard let self, popover.isShown, popover.contentSize != size else { return }
            popover.contentSize = size
        }
    }

    private func maximumHeight(below button: NSStatusBarButton) -> CGFloat {
        guard let window = button.window, let screen = window.screen ?? NSScreen.main else {
            return PopoverView.maximumHeight
        }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = screen.visibleFrame
        // Leave room for the popover arrow and clearance at the bottom of the screen.
        let availableHeight = min(anchor.minY, visibleFrame.maxY) - visibleFrame.minY - 16
        return min(PopoverView.maximumHeight, floor(availableHeight))
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show()
        }
    }
}
