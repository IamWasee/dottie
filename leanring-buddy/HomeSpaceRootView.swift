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
import UniformTypeIdentifiers

struct HomeSpaceRootView: View {
    enum HomeSection: String, CaseIterable, Identifiable {
        case conversation = "Conversation"
        case clickys = "Dots"
        case skills = "Skills"
        case brain = "Brain"
        case meetings = "Meetings"
        case phone = "Phone"
        case settings = "Settings"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .conversation: return "bubble.left.and.bubble.right.fill"
            case .clickys: return "person.2.fill"
            case .skills: return "sparkles"
            case .brain: return "brain.head.profile"
            case .meetings: return "waveform"
            case .phone: return "iphone"
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
                case .brain:
                    HomeBrainView(brain: companionManager.brain)
                case .meetings:
                    HomeMeetingsView(meetingRecorder: companionManager.meetingRecorder)
                case .phone:
                    HomePhoneView(phoneBridge: companionManager.phoneBridge)
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
    /// Pictures waiting to go with the next message.
    @State private var attachedImages: [AttachedImage] = []
    @State private var isDropTargeted = false

    private struct AttachedImage: Identifiable {
        let id = UUID()
        let data: Data
        let thumbnail: NSImage
    }

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
                                HomeConversationEntryView(entry: entry, imageFolderURL: companionManager.imageMemory.folderURL)
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
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DS.Colors.accent, lineWidth: 2)
                .padding(4)
                .opacity(isDropTargeted ? 1 : 0)
        )
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            loadImages(from: providers)
            return true
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

    private var canSend: Bool {
        !typedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedImages) { attachedImage in
                            Image(nsImage: attachedImage.thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        attachedImages.removeAll { $0.id == attachedImage.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(.white)
                                            .background(Circle().fill(Color.black.opacity(0.6)))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 5, y: -5)
                                }
                        }
                    }
                    .padding(.top, 6)
                }
                Text("Dottie saves pictures and remembers them by name, so later you can say \u{201C}go grab that\u{201D}.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            HStack(spacing: 10) {
                Button(action: pickImages) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 15))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Add a picture (or drop or paste one)")
                TextField(attachedImages.isEmpty ? "Type to Dottie" : "Say what it is, like \u{201C}this is my golden sword\u{201D}", text: $typedMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .onSubmit(sendTypedMessage)
                Button(action: sendTypedMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(canSend ? DS.Colors.accent : DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: canSend)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            loadImages(from: providers)
        }
    }

    private func sendTypedMessage() {
        let messageText = typedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let imageDataList = attachedImages.map(\.data)
        typedMessage = ""
        attachedImages = []
        companionManager.sendTypedMessage(messageText, imageDataList: imageDataList)
    }

    private func pickImages() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.image]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.message = "Pick pictures for Dottie to remember"
        guard openPanel.runModal() == .OK else { return }
        for url in openPanel.urls {
            if let data = try? Data(contentsOf: url) { attach(data) }
        }
    }

    /// Dropped or pasted pictures: image files, or image data (a screenshot
    /// copied to the clipboard).
    private func loadImages(from providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return }
                    DispatchQueue.main.async { attach(data) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { attach(data) }
                }
            }
        }
    }

    private func attach(_ data: Data) {
        guard let thumbnail = NSImage(data: data), attachedImages.count < 6 else { return }
        attachedImages.append(AttachedImage(data: data, thumbnail: thumbnail))
    }
}

private struct HomeConversationEntryView: View {
    let entry: ConversationEntry
    let imageFolderURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let imageFileNames = entry.imageFileNames, !imageFileNames.isEmpty {
                HStack(spacing: 6) {
                    Spacer(minLength: 60)
                    ForEach(imageFileNames, id: \.self) { fileName in
                        if let image = NSImage(contentsOf: imageFolderURL.appendingPathComponent(fileName)) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 140, maxHeight: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
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
    @AppStorage(ClickyWorkerConfiguration.userWorkerBaseURLDefaultsKey) private var userWorkerBaseURL = ""
    @AppStorage(ClickyWorkerConfiguration.userAppSharedSecretDefaultsKey) private var userAppSharedSecret = ""
    @State private var serverCheckMessage: String?
    @State private var isCheckingServer = false
    @AppStorage(DictationDictionary.learnsCorrectionsDefaultsKey) private var learnsDictationCorrections = true
    @AppStorage(DictationLanguageCatalog.autoDetectDefaultsKey) private var isDictationLanguageAutoDetected = true
    @AppStorage(DictationLiveTranscriber.enabledDefaultsKey) private var showsDictationLiveText = true
    @AppStorage(DictationLanguageCatalog.languageCodeDefaultsKey) private var dictationLanguageCode = DictationLanguageCatalog.defaultLanguageCode
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
                    settingsRow(label: "Personality") {
                        Picker("", selection: Binding(
                            get: { companionManager.selectedPersonality },
                            set: { companionManager.setSelectedPersonality($0) }
                        )) {
                            ForEach(DottiePersonality.allCases) { personality in
                                Text(personality.displayName).tag(personality)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    settingsHint(companionManager.selectedPersonality.settingsHint)
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
                    settingsRow(label: "Show my words in the notch as I speak") {
                        Toggle("", isOn: $showsDictationLiveText)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsRow(label: "Detect the language automatically") {
                        Toggle("", isOn: $isDictationLanguageAutoDetected)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    if !isDictationLanguageAutoDetected {
                        settingsRow(label: "Language") {
                            Picker("", selection: $dictationLanguageCode) {
                                ForEach(DictationLanguageCatalog.languages) { language in
                                    Text(language.displayName).tag(language.code)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 180)
                        }
                    }
                    settingsHint("Auto-detect follows you across languages, even mid-sentence. Pin one language for the most accurate results.")
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
                    connectionSettings
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

    // MARK: - Connection

    @ViewBuilder
    private var connectionSettings: some View {
        if let builtInWorkerBaseURL = ClickyWorkerConfiguration.builtInWorkerBaseURL, userWorkerBaseURL.isEmpty {
            settingsRow(label: "Server") {
                Text(builtInWorkerBaseURL)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            settingsHint("Built into this copy of Dottie. It holds the Gemini key, so the app never sees it.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Server address")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                HStack(spacing: 8) {
                    TextField("https://dottie.yourname.workers.dev", text: $userWorkerBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button(isCheckingServer ? "Checking…" : "Check") { checkServer() }
                        .disabled(userWorkerBaseURL.isEmpty || isCheckingServer)
                        .pointerCursor()
                }
                SecureField("App secret (only if the server has one)", text: $userAppSharedSecret)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            if let serverCheckMessage {
                Text(serverCheckMessage)
                    .font(.system(size: 11))
                    .foregroundColor(serverCheckMessage.hasPrefix("Connected") ? DS.Colors.textSecondary : DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            settingsHint("This copy of Dottie wasn't built with a server address. Paste the address of the Dottie server (whoever set up Dottie for you has it; INSTALL.md explains how to make one).")
        }
    }

    private func checkServer() {
        isCheckingServer = true
        serverCheckMessage = nil
        let addressToCheck = userWorkerBaseURL
        Task { @MainActor in
            let healthCheckResult = await ClickyWorkerConfiguration.checkHealth(ofBaseURL: addressToCheck)
            isCheckingServer = false
            switch healthCheckResult {
            case .ready:
                serverCheckMessage = "Connected. Dottie is ready to talk."
            case .missingGeminiKey:
                serverCheckMessage = "The server is up but has no Gemini key yet. Add GEMINI_API_KEY to it (see INSTALL.md)."
            case .unreachable(let reason):
                serverCheckMessage = "Couldn't reach it: \(reason)"
            }
        }
    }

    // MARK: - Learned words

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
                .fill(DS.Colors.surface2)
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
