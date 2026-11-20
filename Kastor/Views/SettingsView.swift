import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var launchAtLogin = LoginItemService.isEnabled
    @State private var loginMessageKey: L10nKey?
    @State private var selectedRange: DeleteRange = .today
    @State private var confirmingDelete = false
    @State private var deleteFeedback: String?

    private var lang: AppLanguage { model.language }

    var body: some View {
        @Bindable var bindableModel = model

        VStack(spacing: 0) {
            Picker("", selection: $bindableModel.selectedSettingsTab) {
                Text(L10n.string(.tabGeneral, lang)).tag(SettingsTab.general)
                Text(L10n.string(.tabDelete, lang)).tag(SettingsTab.delete)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()
                .overlay(KastorTheme.divider)

            if model.selectedSettingsTab == .general {
                generalTab
            } else {
                deleteTab
            }
        }
        .frame(width: 440)
        .background(KastorTheme.surface)
        .tint(KastorTheme.accent)
        .environment(\.layoutDirection, lang.isRightToLeft ? .rightToLeft : .leftToRight)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = LoginItemService.isEnabled
            if launchAtLogin { loginMessageKey = nil }
        }
        .onChange(of: model.selectedSettingsTab) {
            deleteFeedback = nil
        }
    }

    private var generalTab: some View {
        Form {
            Picker(L10n.string(.settingsLanguage, lang), selection: Binding(
                get: { model.language },
                set: { model.setLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Text(L10n.string(.settingsSecurity, lang))
                        InfoTipButton(text: L10n.string(.securityInfo, lang))
                    }

                    Spacer()

                    Text(L10n.string(.securityNormal, lang))
                        .font(.callout)
                        .foregroundStyle(model.securityMode == .normal ? KastorTheme.ink : KastorTheme.secondaryInk)
                        .fontWeight(model.securityMode == .normal ? .semibold : .regular)

                    Toggle("", isOn: Binding(
                        get: { model.securityMode == .sensitive },
                        set: { model.setSecurityMode($0 ? .sensitive : .normal) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(KastorTheme.accent)

                    Text(L10n.string(.securitySensitive, lang))
                        .font(.callout)
                        .foregroundStyle(model.securityMode == .sensitive ? KastorTheme.ink : KastorTheme.secondaryInk)
                        .fontWeight(model.securityMode == .sensitive ? .semibold : .regular)
                }
            }

            Picker(L10n.string(.settingsLimit, lang), selection: Binding(
                get: { model.historySize },
                set: { model.setHistorySize($0) }
            )) {
                ForEach(AppModel.historySizes, id: \.self) { size in
                    Text(size.formatted()).tag(size)
                }
            }

            KeyboardShortcuts.Recorder(L10n.string(.settingsShortcut, lang), name: .togglePopover)

            Toggle(L10n.string(.settingsLogin, lang), isOn: Binding(
                get: { launchAtLogin },
                set: { updateLaunchAtLogin($0) }
            ))
            if let loginMessageKey {
                Text(L10n.string(loginMessageKey, lang))
                    .font(.caption)
                    .foregroundStyle(KastorTheme.secondaryInk)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var deleteTab: some View {
        let matchingCount = model.countForDelete(selectedRange)

        return Form {
            Section {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Text(L10n.string(.settingsAutoDelete24h, lang))
                        InfoTipButton(text: L10n.string(.autoDelete24hInfo, lang))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.autoDelete24Hours },
                        set: { model.setAutoDelete24Hours($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(KastorTheme.accent)
                }
            }

            Section {
                ForEach(DeleteRange.allCases) { range in
                    let count = model.countForDelete(range)
                    Button {
                        selectedRange = range
                        deleteFeedback = nil
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedRange == range ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedRange == range ? KastorTheme.accent : KastorTheme.secondaryInk)
                            Text(rangeLabel(range))
                                .foregroundStyle(KastorTheme.ink)
                            Spacer()
                            Text(L10n.itemCount(count, lang))
                                .font(.caption)
                                .foregroundStyle(KastorTheme.secondaryInk)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Text(L10n.string(.deletePinnedNote, lang))
                    .font(.caption)
                    .foregroundStyle(KastorTheme.secondaryInk)
            } header: {
                Text(L10n.string(.deleteRangeHeader, lang))
            }

            Section {
                HStack {
                    if let deleteFeedback {
                        Text(deleteFeedback)
                            .font(.caption)
                            .foregroundStyle(KastorTheme.secondaryInk)
                    } else if matchingCount == 0 {
                        Text(L10n.string(.deleteEmptyHint, lang))
                            .font(.caption)
                            .foregroundStyle(KastorTheme.secondaryInk)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Text(L10n.string(.deleteButton, lang))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(matchingCount == 0)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .alert(L10n.string(.deleteConfirmTitle, lang), isPresented: $confirmingDelete) {
            Button(L10n.string(.deleteAction, lang), role: .destructive) {
                let removed = model.deleteHistory(range: selectedRange)
                deleteFeedback = L10n.deleteDoneFeedback(removed, lang)
            }
            Button(L10n.string(.cancel, lang), role: .cancel) {}
        } message: {
            Text(L10n.deleteConfirmMessage(matchingCount, lang))
        }
    }

    private func rangeLabel(_ range: DeleteRange) -> String {
        switch range {
        case .today: return L10n.string(.rangeToday, lang)
        case .yesterday: return L10n.string(.rangeYesterday, lang)
        case .lastWeek: return L10n.string(.rangeLastWeek, lang)
        case .allTime: return L10n.string(.rangeAllTime, lang)
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemService.set(enabled)
            launchAtLogin = LoginItemService.isEnabled
            loginMessageKey = enabled && !launchAtLogin ? .settingsLoginApproval : nil
        } catch {
            launchAtLogin = LoginItemService.isEnabled
            loginMessageKey = .settingsLoginError
        }
    }
}

private struct InfoTipButton: View {
    let text: String

    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12.5))
                .foregroundStyle(isHovered || isPresented ? KastorTheme.accent : KastorTheme.secondaryInk)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(text)
        .onHover { hovering in
            isHovered = hovering
            isPresented = hovering
        }
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .foregroundStyle(KastorTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
                .background(KastorTheme.surface)
        }
    }
}
