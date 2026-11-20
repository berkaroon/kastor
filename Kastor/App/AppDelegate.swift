import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusBar: StatusBarController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel()
        self.model = model
        statusBar = StatusBarController(model: model)
        model.openSettings = { [weak self] tab in self?.showSettings(tab: tab) }
        model.onLanguageChange = { [weak self] lang in
            self?.statusBar?.updateLocalization()
            self?.settingsWindow?.title = L10n.string(.settingsTitle, lang)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshRetention), name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshRetention), name: .NSSystemClockDidChange, object: nil
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if settingsWindow?.isVisible == true {
            settingsWindow?.makeKeyAndOrderFront(nil)
        } else {
            statusBar?.show()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.flush()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.refreshRetention()
    }

    @objc private func refreshRetention(_ notification: Notification) {
        model?.refreshRetention()
    }

    private func showSettings(tab: SettingsTab = .general) {
        guard let model else { return }
        model.selectedSettingsTab = tab
        model.closePopover?()
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView().environment(model))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.title = L10n.string(.settingsTitle, model.language)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
