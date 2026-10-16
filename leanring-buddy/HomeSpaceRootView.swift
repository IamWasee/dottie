//
//  HomeSpaceRootView.swift
//  leanring-buddy
//
//  Clicky's Home window: the conversation so far, background Clickys, their
//  skills and settings, in one place. Shipped Clicky's Home
//  (HomeSpaceRootView) also holds suggestions; those arrive with a later
//  phase (see ROADMAP.md).
//  HomeWindowManager at the bottom owns the NSWindow.
//

import AppKit
import SwiftUI

struct HomeSpaceRootView: View {
    enum HomeSection: String, CaseIterable, Identifiable {
        case conversation = "Conversation"
        case clickys = "Dots"
        case skills = "Skills"
        case settings = "Settings"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .conversation: return "bubble.left.and.bubble.right.fill"
            case .clickys: return "person.2.fill"
            case .skills: return "sparkles"
            case .settings: return "gearshape.fill"
            }
        }
    }

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var conversationStore: ConversationStore
    @ObservedObject var clickyRoster: ClickyRoster
    @State private var selectedSection: HomeSection = .conversation

    var body: some View {
        HStack(spacing: 0) {
            iconRail
            Divider().background(DS.Colors.borderSubtle)
            Group {
                switch selectedSection {
                case .conversation:
                    HomeConversationView(
                        companionManager: companionManager,
                        conversationStore: conversationStore,
                        shortcutMonitor: companionManager.globalPushToTalkShortcutMonitor
                    )
                case .clickys:
                    HomeClickysView(clickyRoster: clickyRoster)
                case .skills:
                    HomeSkillsView(clickyRoster: clickyRoster, skillLibrary: clickyRoster.skillLibrary)
                case .settings:
                    HomeSettingsView(
                        companionManager: companionManager,
                        conversationStore: conversationStore,
                        shortcutMonitor: companionManager.globalPushToTalkShortcutMonitor
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
        .onReceive(clickyRoster.$agentIDRequestedInHome) { requestedAgentID in
            // The notch asked to show a Dot; HomeClickysView selects it.
            if requestedAgentID != nil {
                selectedSection = .clickys
            }
        }
    }

    private var iconRail: some View {
        VStack(spacing: 6) {
            ForEach(HomeSection.allCases) { section in
                Button(action: { selectedSection = section }) {
                    Image(systemName: section.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(selectedSection == section ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(selectedSection == section ? Color.white.opacity(0.08) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(section.rawValue)
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .background(DS.Colors.surface1)
    }
}

// MARK: - Conversation

private struct HomeConversationView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var conversationStore: ConversationStore
    @ObservedObject var shortcutMonitor: GlobalPushToTalkShortcutMonitor
    @State private var typedMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversation")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text("hold \(shortcutMonitor.talkHotkey.displayText) to talk")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(DS.Colors.borderSubtle)

            if conversationStore.entries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(conversationStore.entries) { entry in
                                HomeConversationEntryView(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(20)
                    }
                    .onAppear {
                        scrollProxy.scrollTo(conversationStore.entries.last?.id, anchor: .bottom)
                    }
                    .onChange(of: conversationStore.entries.count) { _, _ in
                        withAnimation {
                            scrollProxy.scrollTo(conversationStore.entries.last?.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider().background(DS.Colors.borderSubtle)
            composer
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            NotchEyeView(mood: .idle)
                .padding(10)
                .background(Circle().fill(Color.black))
            Text("Nothing here yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Hold \(shortcutMonitor.talkHotkey.displayText) and ask Dottie about anything on your screen.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Type to Dottie", text: $typedMessage)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .onSubmit(sendTypedMessage)
            Button(action: sendTypedMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(typedMessage.isEmpty ? DS.Colors.textTertiary : DS.Colors.accent)
            }
            .buttonStyle(.plain)
            .pointerCursor(isEnabled: !typedMessage.isEmpty)
            .disabled(typedMessage.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func sendTypedMessage() {
        let messageText = typedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageText.isEmpty else { return }
        typedMessage = ""
        companionManager.sendTypedMessage(messageText)
    }
}

private struct HomeConversationEntryView: View {
    let entry: ConversationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !entry.userText.isEmpty {
                HStack {
                    Spacer(minLength: 60)
                    Text(entry.userText)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(DS.Colors.helpChatUserBubble)
                        )
                }
            }
            if !entry.clickyText.isEmpty {
                Text(entry.clickyText)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened) + (entry.inputKind == .typed ? " · typed" : " · voice"))
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }
}

// MARK: - Settings

private struct HomeSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var conversationStore: ConversationStore
    @ObservedObject var shortcutMonitor: GlobalPushToTalkShortcutMonitor

    private let availableVoiceNames = ["Kore", "Puck", "Aoede", "Charon", "Fenrir", "Leda", "Orus", "Zephyr"]
    private let isCuaDriverInstalled = ClickyComputerUse.locateCuaDriverExecutable() != nil
    private let isCuaDriverBundled = ClickyComputerUse.isCuaDriverBundled
    // Same key ClickyComputerUse.isAlwaysAllowed reads.
    @AppStorage("clickyComputerUseAlwaysAllowed") private var isComputerUseAlwaysAllowed = false
    // Same keys ClickyDictationController reads.
    @AppStorage("clickyDictationEnabled") private var isDictationEnabled = true
    @AppStorage(ClickyNotifications.enabledDefaultsKey) private var areDotNotificationsEnabled = true
    @AppStorage(ScreenAnnotationManager.enabledDefaultsKey) private var isScreenAnnotationEnabled = true
    @AppStorage(ClickyDictationController.customWordsDefaultsKey) private var dictationCustomWords = ""
    @AppStorage(DictationDictionary.learnsCorrectionsDefaultsKey) private var learnsDictationCorrections = true
    @ObservedObject private var dictationDictionary = DictationDictionary.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                settingsGroup(title: "Voice") {
                    settingsRow(label: "Dottie's voice") {
                        Picker("", selection: Binding(
                            get: { companionManager.selectedVoiceName },
                            set: { companionManager.setSelectedVoiceName($0) }
                        )) {
                            ForEach(availableVoiceNames, id: \.self) { voiceName in
                                Text(voiceName).tag(voiceName)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    settingsRow(label: "Voice mode") {
                        Text(companionManager.voiceMode == .live ? "Gemini Live" : "Classic")
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    settingsHint("Change CompanionVoiceMode in Info.plist to switch between live and classic.")
                }

                settingsGroup(title: "Shortcuts") {
                    settingsRow(label: "Talk to Dottie") {
                        ClickyHotkeyRecorderField(
                            hotkey: shortcutMonitor.talkHotkey,
                            onRecord: { shortcutMonitor.setTalkHotkey($0) },
                            onRecordingChanged: { shortcutMonitor.isSuspendedForRecording = $0 }
                        )
                    }
                    settingsRow(label: "Dictate") {
                        ClickyHotkeyRecorderField(
                            hotkey: shortcutMonitor.dictationHotkey,
                            onRecord: { shortcutMonitor.setDictationHotkey($0) },
                            onRecordingChanged: { shortcutMonitor.isSuspendedForRecording = $0 }
                        )
                    }
                    if shortcutMonitor.talkHotkey != .defaultTalk || shortcutMonitor.dictationHotkey != .defaultDictation {
                        settingsRow(label: "Back to ctrl + option and right option") {
                            Button("Reset") { shortcutMonitor.resetHotkeysToDefaults() }
                        }
                    }
                    settingsHint("Click a shortcut, then press the new one: modifier keys on their own (like right option or fn), or modifiers with a key (like cmd + shift + space). You hold it the same way to talk or dictate.")
                    settingsRow(label: "Circle things with the cursor while you talk") {
                        Toggle("", isOn: $isScreenAnnotationEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsHint("While you hold the talk shortcut, move the cursor around something to circle it. Dottie sees exactly what you marked.")
                }

                settingsGroup(title: "Appearance") {
                    settingsRow(label: "Show Dottie in the notch") {
                        Toggle("", isOn: Binding(
                            get: { companionManager.isNotchEnabled },
                            set: { companionManager.setNotchEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    settingsRow(label: "Keep the blue cursor visible") {
                        Toggle("", isOn: Binding(
                            get: { companionManager.isClickyCursorEnabled },
                            set: { companionManager.setClickyCursorEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    settingsHint("With the cursor off, it only appears while you're talking to Dottie.")
                    settingsRow(label: "Notify me when a Dot finishes or needs me") {
                        Toggle("", isOn: $areDotNotificationsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsHint("Shown while you're in another app. Click one to open that Dot; a request to use your Mac can be answered right from it.")
                }

                settingsGroup(title: "Dictation") {
                    settingsRow(label: "Hold \(shortcutMonitor.dictationHotkey.displayText) to dictate") {
                        Toggle("", isOn: $isDictationEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Words to spell your way")
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textPrimary)
                        TextField("Names, product words, jargon (comma-separated)", text: $dictationCustomWords)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                    settingsHint("Hold the shortcut, talk, and let go: Dottie types the cleaned-up text wherever your cursor is. If there's nowhere to type, it goes to your clipboard.")
                    settingsRow(label: "Learn words I correct") {
                        Toggle("", isOn: $learnsDictationCorrections)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsHint("When you fix a name or word right after dictating, Dottie adds your spelling to your dictionary and uses it next time.")
                    if !dictationDictionary.learnedCorrections.isEmpty {
                        learnedWordsList
                    }
                }

                settingsGroup(title: "Using your Mac") {
                    settingsRow(label: "Computer-use driver") {
                        Text(isCuaDriverBundled ? "Built in" : (isCuaDriverInstalled ? "Installed" : "Missing"))
                            .foregroundColor(isCuaDriverInstalled ? DS.Colors.textSecondary : DS.Colors.warningText)
                    }
                    settingsRow(label: "Let Dots click and type without asking") {
                        Toggle("", isOn: $isComputerUseAlwaysAllowed)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsHint(isCuaDriverInstalled
                        ? "Dots can always look at your apps. With this off, they ask in the notch before they click or type."
                        : "Dots operate apps through cua-driver, which the build normally puts inside Dottie. This build doesn't have it (it couldn't be downloaded while building). Rebuild with a network connection, or install it with: /bin/bash -c \"$(curl -fsSL https://cua.ai/driver/install.sh)\"")
                }

                settingsGroup(title: "Connection") {
                    settingsRow(label: "Worker") {
                        Text(ClickyWorkerConfiguration.isWorkerConfigured ? ClickyWorkerConfiguration.workerBaseURL : "Not set")
                            .foregroundColor(ClickyWorkerConfiguration.isWorkerConfigured ? DS.Colors.textSecondary : DS.Colors.warningText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    settingsHint("Set ClickyWorkerBaseURL in Info.plist to your Cloudflare Worker's address.")
                }

                settingsGroup(title: "History") {
                    settingsRow(label: "\(conversationStore.entries.count) saved exchanges") {
                        Button("Clear") { conversationStore.clearAll() }
                            .pointerCursor()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
    }

    private func settingsRow<Accessory: View>(label: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            accessory()
                .font(.system(size: 12))
        }
    }

    private var learnedWordsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dictationDictionary.learnedCorrections.count == 1
                     ? "1 learned word"
                     : "\(dictationDictionary.learnedCorrections.count) learned words")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 0)
                Button("Clear all") { dictationDictionary.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(dictationDictionary.learnedCorrections) { learnedCorrection in
                    learnedWordChip(learnedCorrection)
                }
            }
        }
    }

    private func learnedWordChip(_ learnedCorrection: DictationLearnedCorrection) -> some View {
        HStack(spacing: 4) {
            Text(learnedCorrection.corrected)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: { dictationDictionary.remove(word: learnedCorrection.corrected) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Remove this word from your dictionary")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Colors.surface)
        )
        .help("Learned when you changed \u{201C}\(learnedCorrection.original)\u{201D} to \u{201C}\(learnedCorrection.corrected)\u{201D}")
    }

    private func settingsHint(_ hintText: String) -> some View {
        Text(hintText)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Window

@MainActor
final class HomeWindowManager: NSObject, NSWindowDelegate {
    private let companionManager: CompanionManager
    private let conversationStore: ConversationStore
    private let clickyRoster: ClickyRoster
    private var homeWindow: NSWindow?

    init(companionManager: CompanionManager, conversationStore: ConversationStore, clickyRoster: ClickyRoster) {
        self.companionManager = companionManager
        self.conversationStore = conversationStore
        self.clickyRoster = clickyRoster
    }

    func showHomeWindow() {
        if homeWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Dottie"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 560, height: 400)
            window.contentView = NSHostingView(rootView: HomeSpaceRootView(
                companionManager: companionManager,
                conversationStore: conversationStore,
                clickyRoster: clickyRoster
            ))
            window.center()
            window.delegate = self
            homeWindow = window
        }

        // Menu-bar-only apps must activate explicitly for a normal window to
        // come forward and take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        homeWindow?.makeKeyAndOrderFront(nil)
    }
}
