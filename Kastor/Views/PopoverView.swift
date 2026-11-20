import AppKit
import Carbon.HIToolbox
import SwiftUI

struct PopoverView: View {
    static let maximumHeight: CGFloat = 420
    private static let width: CGFloat = 324
    private static let searchHeight: CGFloat = 38
    private static let footerHeight: CGFloat = 34
    private static let dividerHeight: CGFloat = 1
    private static let rowSpacing: CGFloat = 2
    private static let listPadding: CGFloat = 6

    let model: AppModel
    let maximumHeight: CGFloat
    let onResize: (CGSize) -> Void

    @FocusState private var searchFocused: Bool
    @State private var isSearching = false
    @State private var query = ""
    @State private var selectedID: UUID?

    private var lang: AppLanguage { model.language }

    var body: some View {
        let items = model.search(query)
        let size = contentSize(for: items.count, isSearching: isSearching)
        let chromeHeight = Self.chromeHeight(isSearching: isSearching)

        ScrollViewReader { scroll in
            VStack(spacing: 0) {
                history(items)
                    .frame(height: max(0, size.height - chromeHeight))

                if isSearching {
                    Divider()
                        .overlay(KastorTheme.divider)
                        .frame(height: Self.dividerHeight)
                    searchField
                        .frame(height: Self.searchHeight)
                }

                Divider()
                    .overlay(KastorTheme.divider)
                    .frame(height: Self.dividerHeight)

                footer(scroll: scroll)
                    .frame(height: Self.footerHeight)
            }
            .frame(width: size.width, height: size.height)
            .background(KastorTheme.surface)
            .foregroundStyle(KastorTheme.ink)
            .environment(\.layoutDirection, lang.isRightToLeft ? .rightToLeft : .leftToRight)
            .background {
                PopoverKeyMonitor { handleKey($0, scroll: scroll) }
                    .frame(width: 0, height: 0)
            }
            .onChange(of: size, initial: true) { onResize(size) }
            .onChange(of: model.popoverOpenCount, initial: true) {
                isSearching = false
                query = ""
                searchFocused = false
                select(model.entries.first?.id, scroll: scroll)
            }
            .onChange(of: query) {
                select(items.first?.id, scroll: scroll)
            }
            .onChange(of: items.map(\.id)) { oldIDs, newIDs in
                if let selectedID, newIDs.contains(selectedID) { return }
                let oldIndex = selectedID.flatMap { oldIDs.firstIndex(of: $0) } ?? 0
                let nextID = newIDs.isEmpty ? nil : newIDs[min(oldIndex, newIDs.count - 1)]
                select(nextID, scroll: scroll)
            }
        }
    }

    func contentSize(for itemCount: Int, isSearching: Bool = false) -> CGSize {
        let chrome = Self.chromeHeight(isSearching: isSearching)
        let listHeight = itemCount == 0 ? 48 : CGFloat(itemCount) * ItemRow.height
            + CGFloat(itemCount - 1) * Self.rowSpacing + 2 * Self.listPadding
        let height = min(chrome + listHeight, max(chrome, maximumHeight))
        return CGSize(width: Self.width, height: height)
    }

    private static func chromeHeight(isSearching: Bool) -> CGFloat {
        footerHeight + dividerHeight + (isSearching ? searchHeight + dividerHeight : 0)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(KastorTheme.secondaryInk)
                .accessibilityHidden(true)

            TextField(L10n.string(.searchPlaceholder, lang), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(KastorTheme.ink)
                .focused($searchFocused)
                .onAppear { searchFocused = true }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(KastorTheme.secondaryInk)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(KastorTheme.cardSurface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(KastorTheme.divider, lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func history(_ items: [ClipboardItem]) -> some View {
        if items.isEmpty {
            Text(model.entries.isEmpty ? L10n.string(.historyEmpty, lang) : L10n.string(.searchEmpty, lang))
                .font(.callout)
                .foregroundStyle(KastorTheme.secondaryInk)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let firstUnpinnedID = items.first { !$0.isPinned }?.id
            let hasPinned = items.contains(where: \.isPinned)
            ScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(items) { item in
                        if hasPinned, item.id == firstUnpinnedID {
                            Divider()
                                .overlay(KastorTheme.divider)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                        }
                        ItemRow(
                            item: item,
                            isSelected: item.id == selectedID,
                            language: lang,
                            sessionID: model.popoverSessionID,
                            loadImageData: { model.loadImageData(for: item.id) },
                            copy: { model.copy(item) },
                            togglePin: { model.togglePin(item.id) },
                            remove: { model.remove(item.id) }
                        )
                        .id(item.id)
                    }
                }
                .padding(Self.listPadding)
            }
        }
    }

    private func footer(scroll: ScrollViewProxy) -> some View {
        HStack(spacing: 6) {
            Text(L10n.itemCount(model.entries.count, lang))
                .font(.caption)
                .foregroundStyle(KastorTheme.secondaryInk)

            Spacer()

            HStack(spacing: 4) {
                Button {
                    toggleSearch(scroll: scroll)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isSearching ? KastorTheme.accent : KastorTheme.secondaryInk)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSearching ? KastorTheme.accent.opacity(0.16) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string(.searchButton, lang))
                .accessibilityLabel(L10n.string(.searchButton, lang))

                Menu {
                    Button {
                        model.openSettings?(.general)
                    } label: {
                        Text(L10n.string(.settingsOpen, lang))
                    }
                    Button {
                        model.openSettings?(.delete)
                    } label: {
                        Text(L10n.string(.deleteHistoryMenu, lang))
                    }
                    Divider()
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Text(L10n.string(.appQuit, lang))
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(KastorTheme.secondaryInk)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .accessibilityLabel(L10n.string(.historyOptions, lang))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
    }

    private func toggleSearch(scroll: ScrollViewProxy) {
        if isSearching {
            query = ""
            isSearching = false
            searchFocused = false
            select(model.entries.first?.id, scroll: scroll)
        } else {
            isSearching = true
            searchFocused = true
        }
    }

    private func select(_ id: UUID?, scroll: ScrollViewProxy) {
        selectedID = id
        if let id { scroll.scrollTo(id) }
    }

    private func moveSelection(by offset: Int, scroll: ScrollViewProxy) {
        let items = model.search(query)
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selectedID }
        let nextIndex = index.map { min(max($0 + offset, 0), items.count - 1) } ?? 0
        select(items[nextIndex].id, scroll: scroll)
    }

    private var selectedItem: ClipboardItem? {
        model.search(query).first { $0.id == selectedID }
    }

    private func handleKey(_ event: NSEvent, scroll: ScrollViewProxy) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

        switch (Int(event.keyCode), modifiers) {
        case (kVK_ANSI_F, .command):
            if !event.isARepeat { toggleSearch(scroll: scroll) }
        case (kVK_ANSI_P, .command):
            if !event.isARepeat, let selectedItem { model.togglePin(selectedItem.id) }
        case (kVK_UpArrow, []):
            moveSelection(by: -1, scroll: scroll)
        case (kVK_DownArrow, []):
            moveSelection(by: 1, scroll: scroll)
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
            if !event.isARepeat, let selectedItem { model.copy(selectedItem) }
        case (kVK_Escape, []):
            if !event.isARepeat {
                if isSearching {
                    query = ""
                    isSearching = false
                    searchFocused = false
                } else {
                    model.closePopover?()
                }
            }
        case (kVK_Delete, .command):
            if !event.isARepeat, let selectedItem { model.remove(selectedItem.id) }
        default:
            return false
        }
        return true
    }
}

private struct PopoverKeyMonitor: NSViewRepresentable {
    let handleKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handleKey = handleKey
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
        view.handleKey = nil
    }

    final class MonitorView: NSView {
        var handleKey: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window, window.isKeyWindow, event.window === window else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                return handleKey?(event) == true ? nil : event
            }
        }

        func stopMonitoring() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
