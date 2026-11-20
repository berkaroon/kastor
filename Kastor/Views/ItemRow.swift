import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ItemRow: View {
    static let height: CGFloat = 42

    let item: ClipboardItem
    let isSelected: Bool
    let language: AppLanguage
    let sessionID: UUID
    let loadImageData: () -> Data?
    let copy: () -> Void
    let togglePin: () -> Void
    let remove: () -> Void

    @State private var isHovered = false
    @State private var isPinHovered = false
    @State private var isRemoveHovered = false
    @State private var cursorPushed = false

    var body: some View {
        Button(action: copy) {
            label
                .font(.system(size: 13))
                .foregroundStyle(KastorTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.trailing, trailingPadding)
                .frame(height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(
            named: Text(item.isPinned ? L10n.string(.unpinItem, language) : L10n.string(.pinItem, language)),
            togglePin
        )
        .accessibilityAction(named: Text(L10n.string(.removeItem, language)), remove)
        .background(highlight, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .trailing) {
            trailingAccessory
        }
        .onHover { hovering in
            isHovered = hovering
            if !hovering {
                isPinHovered = false
                isRemoveHovered = false
                popCursorIfNeeded()
            }
        }
        .onDisappear {
            popCursorIfNeeded()
        }
    }

    private var trailingPadding: CGFloat {
        if isHovered { return 56 }
        return item.isPinned ? 26 : 10
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if isHovered {
            HStack(spacing: 2) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(isRemoveHovered ? KastorTheme.ink : KastorTheme.secondaryInk)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string(.removeItem, language))
                .accessibilityLabel(L10n.string(.removeItem, language))
                .onHover { hovering in
                    isRemoveHovered = hovering
                    updateCursor()
                }

                Button(action: togglePin) {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(item.isPinned || isPinHovered ? KastorTheme.accent : KastorTheme.secondaryInk)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isPinHovered ? KastorTheme.accent.opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? L10n.string(.unpinItem, language) : L10n.string(.pinItem, language))
                .accessibilityLabel(item.isPinned ? L10n.string(.unpinItem, language) : L10n.string(.pinItem, language))
                .onHover { hovering in
                    isPinHovered = hovering
                    updateCursor()
                }
            }
            .padding(.trailing, 4)
        } else if item.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(KastorTheme.accent.opacity(0.85))
                .accessibilityLabel(L10n.string(.pinnedLabel, language))
                .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch item.kind {
        case .text:
            Text(verbatim: item.previewText ?? "")
                .lineLimit(2)
                .truncationMode(.middle)
        case .image:
            HStack(spacing: 8) {
                ImageThumbnail(itemID: item.id, sessionID: sessionID, loadData: loadImageData)
                    .accessibilityHidden(true)
                Text(L10n.string(.historyImage, language))
                    .lineLimit(1)
            }
        }
    }

    private var highlight: Color {
        if isSelected { return KastorTheme.selectedFill }
        if isHovered { return KastorTheme.hoverFill }
        if item.isPinned { return KastorTheme.pinnedFill }
        return .clear
    }

    private func updateCursor() {
        let shouldShowPointer = isPinHovered || isRemoveHovered
        if shouldShowPointer && !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        } else if !shouldShowPointer {
            popCursorIfNeeded()
        }
    }

    private func popCursorIfNeeded() {
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

private struct ImageThumbnail: View {
    let itemID: UUID
    let sessionID: UUID
    let loadData: () -> Data?

    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 2)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(KastorTheme.secondaryInk)
            }
        }
        .frame(width: 50, height: 32)
        .background(KastorTheme.ink.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: TaskKey(itemID: itemID, sessionID: sessionID)) {
            let pngData = loadData()
            guard let pngData else {
                thumbnail = nil
                return
            }
            let decode = Task.detached(priority: .utility) {
                Self.makeThumbnail(from: pngData)
            }
            let preview = await withTaskCancellationHandler {
                await decode.value
            } onCancel: {
                decode.cancel()
            }
            if !Task.isCancelled { thumbnail = preview }
        }
        .onDisappear {
            thumbnail = nil
        }
    }

    private struct TaskKey: Equatable {
        let itemID: UUID
        let sessionID: UUID
    }

    nonisolated private static func makeThumbnail(from data: Data) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
                kCGImageSourceTypeIdentifierHint: UTType.png.identifier
              ] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier else { return nil }

        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 100,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
